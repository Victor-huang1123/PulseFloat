/// 粒子球的 Metal shader modifier。
///
/// 頂點階段：晶格自轉 → 變形場座標 → l ≤ 4 實球諧場（24 個係數）＋高頻細振動＋起音波前 → 徑向位移，
/// 再把每顆粒子的 4 個頂點沿鏡頭的右／上方向展開成圓點（最小 0.7 px，過小時以覆蓋率補償亮度）。
/// 顏色在頂點階段算好：premultiplied（rgb 可以大於 alpha → 同時有遮蓋與加法光），片段階段只乘上圓點輪廓。
/// 沒有使用 u_time 或任何時間：所有變化都來自 CPU 每幀設定的 uniform（音訊驅動）。
enum ParticleSphereShader {

    static let geometry = """
    #pragma arguments
    float4x4 u_sh0;
    float4x4 u_sh1;
    float4x4 u_lat;
    float4x4 u_fld;
    float4x4 u_pulse;
    float4x4 u_glow;
    float4x4 u_body;

    #pragma varyings
    float4 v_col;
    float3 v_uv;

    #pragma body
    // 每個 float4x4 是 4 個 float4（行 i = SCNMatrix4 的第 i 列）；分開宣告太多參數會超過頂點階段的 buffer 上限
    float4 u_c0 = u_sh0[0], u_c1 = u_sh0[1], u_c2 = u_sh0[2], u_c3 = u_sh0[3];
    float4 u_c4 = u_sh1[0], u_c5 = u_sh1[1], u_motion = u_sh1[2], u_pamp = u_sh1[3];
    float4 u_lat0 = u_lat[0], u_lat1 = u_lat[1], u_lat2 = u_lat[2], u_key = u_lat[3];
    float4 u_fld0 = u_fld[0], u_fld1 = u_fld[1], u_fld2 = u_fld[2], u_view = u_fld[3];
    float4 u_p0 = u_pulse[0], u_p1 = u_pulse[1], u_p2 = u_pulse[2], u_p3 = u_pulse[3];
    float4 u_g0 = u_glow[0], u_g1 = u_glow[1], u_g2 = u_glow[2], u_hot = u_glow[3];
    float4 u_b0 = u_body[0], u_b1 = u_body[1], u_b2 = u_body[2], u_style = u_body[3];
    float3 base = _geometry.position.xyz;
    float4 attr = _geometry.color;
    float2 corner = _geometry.texcoords[0];
    float profile = attr.w;

    // 晶格自轉：u_lat 前三行是 latticeRotation 的三列，p = L · base
    float3 p = float3(dot(u_lat0.xyz, base), dot(u_lat1.xyz, base), dot(u_lat2.xyz, base));
    float r0 = length(p);
    float3 d = r0 > 1.0e-4 ? p / r0 : float3(0.0, 0.0, 1.0);
    float3 f = float3(dot(u_fld0.xyz, d), dot(u_fld1.xyz, d), dot(u_fld2.xyz, d));
    float x = f.x, y = f.y, z = f.z;
    float x2 = x * x, y2 = y * y, z2 = z * z;

    // l = 1...4 實球諧場（係數已含增益與正負號）
    float field = u_c0.x * x + u_c0.y * y + u_c0.z * z
        + u_c0.w * (2.0 * x * y) + u_c1.x * (2.0 * y * z) + u_c1.y * (1.5 * z2 - 0.5) + u_c1.z * (2.0 * x * z) + u_c1.w * (x2 - y2)
        + u_c2.x * (y * (3.0 * x2 - y2)) + u_c2.y * (5.2 * x * y * z) + u_c2.z * (0.726 * y * (5.0 * z2 - 1.0))
        + u_c2.w * (0.5 * z * (5.0 * z2 - 3.0)) + u_c3.x * (0.726 * x * (5.0 * z2 - 1.0)) + u_c3.y * (2.6 * z * (x2 - y2))
        + u_c3.z * (x * (x2 - 3.0 * y2))
        + u_c3.w * (4.0 * x * y * (x2 - y2)) + u_c4.x * (3.08 * y * z * (3.0 * x2 - y2)) + u_c4.y * (1.555 * x * y * (7.0 * z2 - 1.0))
        + u_c4.z * (0.947 * y * z * (7.0 * z2 - 3.0)) + u_c4.w * (0.125 * (35.0 * z2 * z2 - 30.0 * z2 + 3.0))
        + u_c5.x * (0.947 * x * z * (7.0 * z2 - 3.0)) + u_c5.y * (0.778 * (x2 - y2) * (7.0 * z2 - 1.0))
        + u_c5.z * (3.08 * x * z * (x2 - 3.0 * y2)) + u_c5.w * (x2 * (x2 - 3.0 * y2) - y2 * (3.0 * x2 - y2));

    // 高頻細振動：空間上連續的細紋，相位只隨音訊前進
    float ph = u_motion.z;
    float hf = sin(dot(f, float3(11.0, 7.0, -5.0)) + ph) * sin(dot(f, float3(-6.0, 12.0, 8.0)) + 1.3 * ph)
             + 0.6 * sin(dot(f, float3(4.0, -9.0, 13.0)) - 0.8 * ph);

    // 起音波前：路徑長 = 由球心往外 + 沿球面離起點的角距離（先點亮起點，再以環狀擴散到整顆球與外圍）
    float path = r0 * 0.55;
    float pulse = 0.0;
    float s;
    s = (path + 0.5 * acos(clamp(dot(f, u_p0.xyz), -1.0, 1.0)) - u_p0.w) * 8.0; pulse += u_pamp.x * exp(-s * s);
    s = (path + 0.5 * acos(clamp(dot(f, u_p1.xyz), -1.0, 1.0)) - u_p1.w) * 8.0; pulse += u_pamp.y * exp(-s * s);
    s = (path + 0.5 * acos(clamp(dot(f, u_p2.xyz), -1.0, 1.0)) - u_p2.w) * 8.0; pulse += u_pamp.z * exp(-s * s);
    s = (path + 0.5 * acos(clamp(dot(f, u_p3.xyz), -1.0, 1.0)) - u_p3.w) * 8.0; pulse += u_pamp.w * exp(-s * s);
    pulse = min(pulse, 1.2);

    float resp = attr.y;
    float rr = r0 * (1.0 + u_motion.x * (0.55 + 0.45 * resp)) + r0 * resp * (field + u_motion.y * hf) + 0.06 * pulse * resp;
    float3 pos = d * rr;
    float energy = clamp(max(field, 0.0) * 4.5 + 1.1 * pulse + u_motion.y * 16.0 * max(hf, 0.0), 0.0, 1.0);

    // 深度（相對球心，+1 朝鏡頭）與每單位的像素數
    float4 vc = scn_node.modelViewTransform * float4(pos, 1.0);
    float4 v0 = scn_node.modelViewTransform * float4(0.0, 0.0, 0.0, 1.0);
    float facing = 0.5 + 0.5 * clamp((vc.z - v0.z) / 1.25, -1.0, 1.0);
    float pxPerUnit = scn_frame.projectionTransform[1][1] * 0.5 / (scn_frame.inverseResolution.y * max(0.05, -vc.z));

    bool isGlow = profile > 0.5 && profile < 1.5;
    bool isLine = profile > 1.5 && profile < 2.5;
    bool isHot = profile > 2.5;
    float cover = 1.0;
    if (!isLine) {
        float size = attr.x * (1.0 + 0.45 * energy);
        if (isGlow) { size *= 1.0 + 0.35 * u_motion.w + u_motion.x; }
        float minSize = 0.7 / pxPerUnit;
        if (size < minSize) { cover = (size * size) / (minSize * minSize); size = minSize; }
        float3 right = normalize((scn_node.inverseModelViewTransform * float4(1.0, 0.0, 0.0, 0.0)).xyz);
        float3 up = normalize((scn_node.inverseModelViewTransform * float4(0.0, 1.0, 0.0, 0.0)).xyz);
        pos += (right * corner.x + up * corner.y) * size;
    }
    _geometry.position = float4(pos, 1.0);

    // 顏色：場座標的高度決定漸層位置，能量把顏色推向熱色；假的主光與深度讓球有體積
    float t = clamp(0.5 + 0.42 * y + 0.2 * (r0 - 0.9), 0.0, 1.0);
    float3 g = t < 0.5 ? mix(u_g0.xyz, u_g1.xyz, t * 2.0) : mix(u_g1.xyz, u_g2.xyz, t * 2.0 - 1.0);
    float3 b = t < 0.5 ? mix(u_b0.xyz, u_b1.xyz, t * 2.0) : mix(u_b1.xyz, u_b2.xyz, t * 2.0 - 1.0);
    float3 wn = normalize((scn_node.modelTransform * float4(d, 0.0)).xyz);
    float key = max(dot(wn, u_key.xyz), 0.0);
    float lit = (0.5 + 0.5 * key) * (0.35 + 0.65 * facing);
    float depthCover = 0.4 + 0.6 * facing;
    float bright = attr.z * cover;
    float heat = energy;
    float bodyOpacity = u_style.x;
    if (isHot) { heat = 0.5 + 0.5 * u_motion.w; lit = 0.7 + 0.3 * facing; depthCover = 1.0; }
    if (isGlow) { bright *= 0.45 + 0.9 * u_motion.w; lit = 1.0; heat = 0.35 + 0.65 * u_motion.w; bodyOpacity = u_style.z; depthCover = 1.0; }
    if (isLine) { bright *= (0.12 + 1.6 * energy) * u_view.y * clamp((pxPerUnit - 40.0) / 90.0, 0.0, 1.0); }
    float3 glow = mix(g, u_hot.xyz, clamp(heat * u_hot.w, 0.0, 1.0));
    // 輪廓光（fresnel）：殼層在剪影邊緣稍亮，球的邊界清楚
    float3 nv = normalize((scn_node.modelViewTransform * float4(d, 0.0)).xyz);
    float rim = (isGlow || isHot) ? 0.0 : pow(1.0 - abs(dot(nv, normalize(-vc.xyz))), 3.0) * step(0.7, resp);
    // 遮蓋（alpha）主要由深度決定，光照只影響發光：淺色桌布上整顆球的覆蓋率夠，深色桌布上有明暗與體積
    float vis = bright * depthCover;
    float alpha = clamp(vis * bodyOpacity, 0.0, 1.0);
    float emit = vis * u_style.y * (lit * (0.32 + 1.3 * heat) + 0.55 * rim);
    // 核心光暈：以半透明的本體色「染色」為主、加法光為輔（淺色桌布上才不會變成一團白霧）
    if (isGlow) { emit = bright * u_style.y * (0.22 + 0.5 * u_motion.w); }
    float3 col = b * alpha * (0.75 + 0.25 * lit) + glow * emit;
    out.v_col = float4(col, alpha);
    out.v_uv = float3(corner, profile);
    """

    static let fragment = """
    #pragma varyings
    float4 v_col;
    float3 v_uv;

    #pragma body
    float2 uv = in.v_uv.xy;
    float r2 = dot(uv, uv);
    float prof = in.v_uv.z;
    float a = 1.0;
    if (prof < 0.5 || prof > 2.5) {
        // 柔和但有輪廓的圓點：中心平台、邊緣快速收掉
        float edge = clamp(1.0 - r2, 0.0, 1.0);
        a = pow(edge, 1.4);
    } else if (prof < 1.5) {
        float edge = clamp(1.0 - r2, 0.0, 1.0);
        a = edge * edge * exp(-r2 * 2.5);
    }
    _output.color = in.v_col * a;
    """
}
