/// 音訊地形的 shader modifier（Metal）。
///
/// 資料流：`TerrainHistory` 把頻譜切片寫進一張 rgba32Float 小貼圖（每列一個切片的環狀緩衝，最後一列是參數），
/// geometry modifier 用整數座標 `read()` 取高度、算法線並把網格往後捲動；fragment modifier 自己算光照與線條。
///
/// 實測（Xcode 26.6）：
/// - 自訂參數要寫在 `#pragma arguments` 區段，而且「哪個 modifier 用到就在哪個 modifier 宣告」（同名可在兩處重複宣告）。
///   `uniform texture2d<float>` 的寫法編譯會失敗（洋紅色）。
/// - `#pragma varyings` 可以把 geometry 的值傳給 fragment（`out.x` / `in.x`）。
/// - `_surface.diffuse` 與 `_output.color` 都是 premultiplied alpha。
/// - 輸出貼圖是 bgra8Unorm，SceneKit 不做 gamma 編碼，所以這裡的顏色一律用顯示空間（sRGB 0...1）的值。
enum TerrainShaders {
    /// 地形頂點計算共用的函式（放在所有 pragma 之前）。
    private static let helpers = """
    float tr_depthOf(int k, float frac, int rows, float depth) {
        if (k <= 0) { return 0.0; }
        float dz = depth / float(max(rows - 2, 1));
        return clamp((float(k) - 1.0 + frac) * dz, 0.0, depth);
    }
    uint tr_slotOf(int head, int k, int rows) {
        int s = (head + 1 - k) % rows;
        if (s < 0) { s += rows; }
        return uint(s);
    }
    float tr_heightOf(float v, float s, float depth, float curve, float taperStart, float u, float edge) {
        float taper = 1.0 - smoothstep(depth * taperStart, depth, s);
        if (edge > 0.0) { taper *= smoothstep(0.0, edge, u) * smoothstep(1.0, 1.0 - edge, u); }
        return pow(clamp(v, 0.0, 1.0), curve) * taper;
    }

    """

    /// 頂點共用的開頭：讀參數列、算出這個頂點的深度、切片與高度。
    private static let vertexPrologue = """
    int cols = int(u_hist.get_width());
    int rows = int(u_hist.get_height()) - 1;
    float4 P = u_hist.read(uint2(0, uint(rows)));
    int head = int(P.x + 0.5);
    float frac = P.y;
    float u = _geometry.texcoords[0].x;
    int k = int(_geometry.texcoords[0].y + 0.5);
    int col = clamp(int(u * float(cols - 1) + 0.5), 0, cols - 1);
    float W = u_dims.x;
    float D = u_dims.y;
    float H = u_dims.z;
    float zf = u_dims.w;
    float s = tr_depthOf(k, frac, rows, D);
    uint slot = tr_slotOf(head, k, rows);
    float4 c0 = u_hist.read(uint2(uint(col), slot));
    float hn = tr_heightOf(c0.r, s, D, u_shape.x, u_shape.w, u, u_edge.x);

    """

    /// 地形曲面：位移、由相鄰切片算平滑法線、把座標交給 fragment。
    static let surfaceGeometry = helpers + """
    #pragma arguments
    texture2d<float> u_hist;
    float4 u_dims;
    float4 u_shape;
    float4 u_edge;
    #pragma varyings
    float4 tv;
    float4 tw;
    #pragma body

    """ + vertexPrologue + """
    int cl = max(col - 1, 0);
    int cr = min(col + 1, cols - 1);
    int kf = max(k - 1, 0);
    int kb = min(k + 1, rows - 1);
    float sf = tr_depthOf(kf, frac, rows, D);
    float sb = tr_depthOf(kb, frac, rows, D);
    float du = 1.0 / float(max(cols - 1, 1));
    float hl = tr_heightOf(u_hist.read(uint2(uint(cl), slot)).r, s, D, u_shape.x, u_shape.w, float(cl) * du, u_edge.x);
    float hr = tr_heightOf(u_hist.read(uint2(uint(cr), slot)).r, s, D, u_shape.x, u_shape.w, float(cr) * du, u_edge.x);
    float hf = tr_heightOf(u_hist.read(uint2(uint(col), tr_slotOf(head, kf, rows))).r, sf, D, u_shape.x, u_shape.w, u, u_edge.x);
    float hb = tr_heightOf(u_hist.read(uint2(uint(col), tr_slotOf(head, kb, rows))).r, sb, D, u_shape.x, u_shape.w, u, u_edge.x);
    float dx = max(float(cr - cl), 1.0) * W / float(max(cols - 1, 1));
    float dz = max(sb - sf, D / float(max(rows - 2, 1)));
    _geometry.position = float4((u - 0.5) * W, hn * H, zf - s, 1.0);
    _geometry.normal = normalize(float3(-(hr - hl) * H / dx, 1.0, (hb - hf) * H / dz));
    out.tv = float4(u, (P.z - float(k)) / max(u_shape.z, 1.0), s / D, hn);
    out.tw = float4(c0.g, float(k), P.w, 0.0);
    """

    /// 地形曲面的著色：高度漸層、柔和光照、菲涅耳、景深淡出，再疊上抗鋸齒的線（時間切片、頻率格線、前緣、等高線）。
    static let surfaceFragment = """
    #pragma arguments
    float4 u_fillLow;
    float4 u_fillHigh;
    float4 u_fillHot;
    float4 u_lineCol;
    float4 u_lineHot;
    float4 u_beatCol;
    float4 u_keyLight;
    float4 u_fillLight;
    float4 u_shade;
    float4 u_lines;
    float4 u_mode;
    float4 u_edge;
    #pragma transparent
    #pragma body
    float3 N = normalize(_surface.normal);
    float3 V = normalize(_surface.view);
    if (dot(N, V) < 0.0) { N = -N; }
    float3 L = normalize((scn_frame.viewTransform * float4(u_keyLight.xyz, 0.0)).xyz);
    float3 L2 = normalize((scn_frame.viewTransform * float4(u_fillLight.xyz, 0.0)).xyz);
    float hn = in.tv.w;
    float sd = in.tv.z;
    float beat = saturate(in.tw.x);

    // 填色：高度漸層 × 包覆式漫射 + 谷底遮蔽，菲涅耳讓掠射角較不透明
    float3 albedo = mix(u_fillLow.rgb, u_fillHigh.rgb, smoothstep(0.0, 0.85, hn));
    albedo = mix(albedo, u_fillHot.rgb, smoothstep(0.6, 1.0, hn) * u_fillHot.a);
    float3 up = normalize((scn_frame.viewTransform * float4(0.0, 1.0, 0.0, 0.0)).xyz);
    float wrap = saturate((dot(N, L) + 0.3) / 1.3);
    float light = u_shade.x * mix(0.7, 1.0, saturate(dot(N, up))) + u_keyLight.w * wrap + u_fillLight.w * saturate(dot(N, L2));
    light *= mix(0.74, 1.0, smoothstep(0.0, 0.4, hn));
    float3 Hv = normalize(L + V);
    float spec = u_shade.y * pow(saturate(dot(N, Hv)), u_shade.z);
    float fres = pow(1.0 - saturate(dot(N, V)), 3.0);
    float a = mix(u_fillLow.a, u_fillHigh.a, smoothstep(0.05, 1.0, sd));
    a = saturate(a + fres * u_shade.w * (1.0 - a));
    float3 rgb = albedo * light + u_beatCol.rgb * (beat * u_mode.y * u_beatCol.a);
    float4 color = float4(rgb * a + spec * (0.4 + 0.6 * a), a);
    float fog = mix(1.0, u_mode.x, smoothstep(0.18, 1.0, sd));
    if (u_edge.y > 0.0) { fog *= smoothstep(0.0, u_edge.y, in.tv.x) * smoothstep(1.0, 1.0 - u_edge.y, in.tv.x); }
    color *= fog;

    // 線：fwidth 抗鋸齒；太密時（小視窗、遠處）只留每隔一條，再密才淡出
    float rc = in.tv.y;
    float fr = max(fwidth(rc), 1e-5);
    float r0 = saturate(u_lines.x * 0.5 + 0.5 - abs(fract(rc + 0.5) - 0.5) / fr);
    float r1 = saturate(u_lines.x * 0.5 + 0.5 - abs(fract(rc * 0.5 + 0.5) - 0.5) / (fr * 0.5));
    float rowLine = mix(r0, r1, smoothstep(0.12, 0.24, fr)) * (1.0 - smoothstep(0.32, 0.8, fr));
    float cc = in.tv.x * u_lines.z;
    float fc = max(fwidth(cc), 1e-5);
    float c0l = saturate(u_lines.x * 0.5 + 0.5 - abs(fract(cc + 0.5) - 0.5) / fc);
    float c1l = saturate(u_lines.x * 0.5 + 0.5 - abs(fract(cc * 0.5 + 0.5) - 0.5) / (fc * 0.5));
    float colLine = mix(c0l, c1l, smoothstep(0.12, 0.24, fc)) * (1.0 - smoothstep(0.32, 0.8, fc));
    float kk = in.tw.y;
    float fk = max(fwidth(kk), 1e-5);
    float front = saturate(u_lines.y * (1.0 + 0.6 * in.tw.z) + 0.5 - kk / fk);
    float contour = 0.0;
    if (u_lines.w > 0.0) {
        float hc = hn / u_lines.w;
        float fh = max(fwidth(hc), 1e-5);
        contour = saturate(1.0 - abs(fract(hc + 0.5) - 0.5) / fh) * (1.0 - smoothstep(0.2, 0.5, fh)) * smoothstep(0.01, 0.05, hn);
    }
    float3 lc = mix(u_lineCol.rgb, u_lineHot.rgb, smoothstep(0.5, 1.0, hn));
    lc = mix(lc, u_beatCol.rgb, beat * (1.0 - u_mode.y));
    float la = max(max(rowLine * u_mode.w * (1.0 + beat * (1.0 - u_mode.y)), colLine * u_lineHot.a), max(front, contour * u_mode.z));
    la = saturate(la) * u_lineCol.a * fog;
    _output.color = color * (1.0 - la) + float4(lc * la, la);
    """

    /// 雕塑模式的切面（四周裙邊）：底部頂點固定在台座底，頂部頂點跟著地形高度。
    static let skirtGeometry = helpers + """
    #pragma arguments
    texture2d<float> u_hist;
    float4 u_dims;
    float4 u_shape;
    float4 u_edge;
    #pragma varyings
    float4 sv;
    float4 sw;
    #pragma body
    float top = _geometry.position.y;

    """ + vertexPrologue + """
    float y = top > 0.5 ? hn * H : -u_shape.y;
    _geometry.position = float4((u - 0.5) * W, y, zf - s, 1.0);
    out.sv = float4(top, y, hn, s / D);
    out.sw = float4(c0.g, P.w, 0.0, 0.0);
    """

    /// 切面著色：不透明的剖面、地層線、地面線，頂緣是剖面輪廓線（前面的切面就是即時頻譜的剪影）。
    static let skirtFragment = """
    #pragma arguments
    float4 u_face;
    float4 u_faceLow;
    float4 u_rimCol;
    float4 u_rimHot;
    float4 u_keyLight;
    float4 u_fillLight;
    float4 u_shade;
    float4 u_faceDims;
    #pragma body
    float3 N = normalize(_surface.normal);
    float3 L = normalize((scn_frame.viewTransform * float4(u_keyLight.xyz, 0.0)).xyz);
    float3 L2 = normalize((scn_frame.viewTransform * float4(u_fillLight.xyz, 0.0)).xyz);
    float t = in.sv.x;
    float y = in.sv.y;
    float hn = in.sv.z;
    float fog = mix(1.0, u_faceDims.w, smoothstep(0.3, 1.0, in.sv.w));
    float light = u_shade.x + u_keyLight.w * saturate((dot(N, L) + 0.3) / 1.3) + u_fillLight.w * saturate(dot(N, L2));
    float slab = 1.0 - step(0.0, y);
    float3 base = mix(u_face.rgb, u_faceLow.rgb, slab);
    base *= mix(0.8, 1.0, smoothstep(-u_faceDims.y, u_faceDims.x * 0.6, y));
    float3 rgb = base * light;
    float sc = y / max(u_rimHot.a, 1e-3);
    float fs = max(fwidth(sc), 1e-5);
    float strata = saturate(1.0 - abs(fract(sc + 0.5) - 0.5) / fs) * (1.0 - slab) * (1.0 - smoothstep(0.2, 0.5, fs)) * u_face.a;
    float fy = max(fwidth(y), 1e-6);
    float ground = saturate(1.0 - abs(y) / fy) * u_faceLow.a;
    float ft = max(fwidth(t), 1e-5);
    float rim = saturate(u_rimCol.a * (1.0 + 0.6 * in.sw.y) + 0.5 - (1.0 - t) / ft);
    // 幾乎側對鏡頭的切面：fwidth 會爆大，線條改為淡出，避免整面被輪廓線塗滿。
    float facing = smoothstep(0.06, 0.25, abs(dot(N, normalize(_surface.view))));
    float3 rc = mix(u_rimCol.rgb, u_rimHot.rgb, smoothstep(0.35, 0.95, hn));
    float m = saturate(max(max(strata, ground) * fog, rim) * facing);
    rgb = mix(rgb, rc, m);
    _output.color = float4(rgb, 1.0);
    """
}
