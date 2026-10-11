import SceneKit

/// 黑洞主題的 Metal shader modifier。
///
/// 每個材質都宣告同一組參數：
/// - `u_dyn0`（每幀）：第 0 欄 流動相位（盤面、螺旋、軌道、中頻）；第 1 欄 厚度、亮度、高頻、火花；
///   第 2 欄 中頻、核心脈動、左右平衡、立體聲寬度；第 3 欄 四個起音脈衝的半徑。
/// - `u_dyn1`（每幀）：第 0 欄 四個脈衝的強度；第 1 欄 環的三個中頻諧波與火花種子；
///   第 2 欄 核心縮放、低頻、響度、軌道速率；第 3 欄 x = 盤面節點朝向鏡頭的偏航角（圖樣用世界角度，不跟著轉）。
/// - `u_shape`：盤內半徑、盤外半徑、陰影半徑、透鏡愛因斯坦半徑（世界單位，黑洞距離處）。
/// - `u_mode`：各材質自己的模式參數。
/// - `u_hot` / `u_mid` / `u_cool` / `u_dust`：風格色（線性 RGB；w 為額外參數）。
/// - `u_style`：發光強度、不透明度、塵帶強度、都卜勒速度。
///
/// 透鏡是「視覺近似」：把弱場點質量透鏡方程式逐頂點套在黑洞後方的幾何上（盤面遠側因此彎過陰影上方），
/// 次級像重新對應成陰影下緣的細環；不是廣義相對論的光線追蹤。
enum BlackHoleShaders {
    /// 共用函式（用 #ifndef 防止同一個材質的兩個 entry point 重複定義）。
    static let common = """
    #ifndef BH_COMMON
    #define BH_COMMON
    inline float bh_hash(int2 p) {
        uint2 q = as_type<uint2>(p) * uint2(1597334673u, 3812015801u);
        uint n = (q.x ^ q.y) * 1597334673u;
        n ^= n >> 16u;
        n *= 2246822519u;
        n ^= n >> 13u;
        return float(n) * 2.3283064e-10;
    }
    // 值噪聲；x 方向以 period（整數格）為週期，讓圓盤的角度方向無縫。
    inline float bh_noise(float2 x, int period) {
        float2 fl = floor(x);
        float2 f = x - fl;
        float2 u = f * f * (3.0 - 2.0 * f);
        int ix = int(fl.x);
        int iy = int(fl.y);
        int x0 = ((ix % period) + period) % period;
        int x1 = (x0 + 1) % period;
        float a = bh_hash(int2(x0, iy));
        float b = bh_hash(int2(x1, iy));
        float c = bh_hash(int2(x0, iy + 1));
        float d = bh_hash(int2(x1, iy + 1));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }
    inline float bh_fbm(float2 x, int period, int octaves, float seed) {
        float sum = 0.0;
        float amp = 0.5;
        float norm = 0.0;
        float2 offset = float2(0.0, seed * 7.0);
        for (int i = 0; i < octaves; i++) {
            sum += amp * bh_noise(x + offset, period);
            norm += amp;
            amp *= 0.5;
            x *= 2.0;
            period *= 2;
            offset = float2(0.0, offset.y * 1.5 + 5.3);
        }
        return sum / max(norm, 1e-4);
    }
    // 點質量透鏡（視空間）。mode 0：主像（往外推）；mode 1：次級像（對側，重新對應到陰影外緣的細環）。
    // 只有在黑洞中心平面後方的點才偏折，偏折量隨深度平滑增加，所以幾何保持連續。
    inline float3 bh_lens(float3 p, float3 hole, float RE, float d0, float mode, float rsAngle, thread float &weight) {
        float dp = max(-p.z, 1e-3);
        float dh = max(-hole.z, 1e-3);
        float2 hc = hole.xy / dh;
        float2 a = p.xy / dp - hc;
        float behind = dp - dh;
        float b2 = max(behind, 0.0) * max(behind, 0.0);
        float k = b2 / (b2 + d0 * d0);   // C1 平滑：穿過黑洞中心平面時不會有折角
        float te = RE / dh * sqrt(k);
        float b = length(a);
        float2 dir = b > 1e-6 ? a / b : float2(0.0, 1.0);
        float root = sqrt(b * b + 4.0 * te * te);
        float2 a2;
        float z = p.z;
        if (mode < 0.5) {
            a2 = dir * (0.5 * (b + root));
            weight = 1.0;
        } else {
            float bm = 0.5 * (root - b);
            float q = te > 1e-6 ? clamp(bm / te, 0.0, 1.0) : 0.0;
            a2 = -dir * rsAngle * (1.0 + 0.16 * q * q);
            weight = q * q * q;
            z = hole.z - 0.02;
        }
        return float3((a2 + hc) * dp, z);
    }
    // 細環的中心線（模型空間）：中頻諧波讓環變形，midPhase 只以整數倍出現（可在 2π 處折回）。
    inline float3 bh_ring_point(float t, float R0, float inc, float nd, float4 h, float mp, float mid) {
        float rr = R0 * (1.0 + h.x * 0.026 * cos(2.0 * t + mp + nd)
                              + h.y * 0.018 * cos(3.0 * t - 2.0 * mp + 2.0 * nd)
                              + h.z * 0.012 * cos(5.0 * t + 3.0 * mp));
        float y = R0 * mid * 0.022 * sin(3.0 * t - mp + 2.0 * nd);
        float3 p = float3(rr * cos(t), y, -rr * sin(t));
        float ci = cos(inc);
        float si = sin(inc);
        p = float3(p.x, p.y * ci - p.z * si, p.y * si + p.z * ci);
        float cn = cos(nd);
        float sn = sin(nd);
        return float3(p.x * cn + p.z * sn, p.y, -p.x * sn + p.z * cn);
    }
    // 軌道平面 → 模型空間：近點角（繞 y）、傾角（繞 x）、節點（繞 y）。
    inline float3 bh_orient(float3 p, float3 o) {
        float cw = cos(o.z);
        float sw = sin(o.z);
        p = float3(p.x * cw + p.z * sw, p.y, -p.x * sw + p.z * cw);
        float ci = cos(o.x);
        float si = sin(o.x);
        p = float3(p.x, p.y * ci - p.z * si, p.y * si + p.z * ci);
        float cn = cos(o.y);
        float sn = sin(o.y);
        return float3(p.x * cn + p.z * sn, p.y, -p.x * sn + p.z * cn);
    }
    // 鏡頭到 p 的視線是否穿過盤面（y = 0、rIn...rOut）：1 = p 被盤面擋在後面。用來把粒子與細環分成盤後、盤前兩趟。
    inline float bh_disk_cover(float3 p, float3 cam, float rIn, float rOut) {
        float dy = cam.y - p.y;
        if (abs(dy) < 1e-5 || (cam.y > 0.0) == (p.y > 0.0)) { return 0.0; }
        float t = cam.y / dy;
        float3 hit = cam + (p - cam) * t;
        float r = length(hit.xz);
        return smoothstep(rIn * 0.9, rIn * 1.06, r) * (1.0 - smoothstep(rOut * 0.72, rOut * 0.96, r));
    }
    // 輸出 premultiplied 顏色：light 是發出的光（可以大於 opacity，等於加法光），opacity 是遮住底色的比例。
    // 材質用貼圖型的半透明 diffuse + .alpha 混合，SceneKit 會用 (one, 1−srcAlpha)：rgb = 光 + 底 × (1−a)。
    #define BH_OUTPUT(light, opacity) { _output.color = float4((light), clamp((opacity), 0.0, 1.0)); }
    #endif

    """

    static let arguments = """
    #pragma arguments
    float4x4 u_dyn0;
    float4x4 u_dyn1;
    float4 u_shape;
    float4 u_mode;
    float4 u_hot;
    float4 u_mid;
    float4 u_cool;
    float4 u_dust;
    float4 u_style;

    """

    // MARK: - 吸積盤

    /// 吸積盤頂點：u_mode.x 0 主像（寫深度）、2 次級像；u_mode.y 厚度倍率；u_mode.z 透鏡深度衰減；u_mode.w 噪聲層數。
    static let diskGeometry = common + arguments + """
    #pragma varyings
    float4 v_disk;
    float2 v_aux;
    #pragma body
    float2 uv = _geometry.texcoords[0];
    float psi = uv.x * 6.2831853;
    float s = uv.y;
    float rIn = u_shape.x;
    float rOut = u_shape.y;
    float r = mix(rIn, rOut, s);
    float lr = log(r / rIn);
    float4x4 mv = scn_node.modelViewTransform;
    float4x4 imv = scn_node.inverseModelViewTransform;
    float3 camM = (imv * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float3 rightM = normalize((imv * float4(1.0, 0.0, 0.0, 0.0)).xyz);
    float3 p = float3(r * cos(psi), 0.0, r * sin(psi));
    float side = dot(normalize(p), rightM);
    // 盤面節點會轉向鏡頭（讓遠側半圈先畫）；圖樣用世界角度，所以減掉節點的偏航角
    float psiW = psi - u_dyn1[3].x;
    // 厚度：低頻撐開，螺旋密度波讓表面起伏，起音脈衝經過時鼓起
    float prof = smoothstep(0.0, 0.10, s) * (1.0 - 0.6 * s);
    float spiral = 0.5 + 0.5 * cos(2.0 * psiW + 9.0 * lr - u_dyn0[0].y);
    float h = (0.012 + 0.085 * u_dyn0[1].x) * prof * (0.7 + 0.6 * spiral);
    float ripple = 0.0;
    for (int k = 0; k < 4; k++) {
        float dr = (r - u_dyn0[3][k]) / 0.09;
        ripple += u_dyn1[0][k] * exp(-dr * dr);
    }
    h += 0.035 * ripple * prof;
    h *= 1.0 + 0.4 * u_dyn0[2].z * side;
    p.y = h * u_mode.y;
    float3 v = (mv * float4(p, 1.0)).xyz;
    float3 hole = (mv * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float rsAngle = u_shape.z * u_dyn1[2].x / max(-hole.z, 1e-3);
    float weight = 1.0;
    float3 lv = bh_lens(v, hole, u_shape.w, u_mode.z, u_mode.x > 1.5 ? 1.0 : 0.0, rsAngle, weight);
    _geometry.position = imv * float4(lv, 1.0);
    // 相對論性射束（近似）：朝鏡頭運動的一側較亮
    float3 toCam = normalize(camM - p);
    float3 tang = float3(sin(psi), 0.0, -cos(psi));
    float beta = u_style.w * sqrt(rIn / r);
    float dop = sqrt(1.0 - beta * beta) / (1.0 - beta * dot(tang, toCam));
    out.v_disk = float4(uv.x, s, dop, weight);
    out.v_aux = float2(side, 0.0);
    """

    static let diskFragment = common + arguments + """
    #pragma body
    float u = in.v_disk.x;
    float s = clamp(in.v_disk.y, 0.0, 1.0);
    float beam = pow(clamp(in.v_disk.z, 0.2, 2.2), 2.4);
    float weight = in.v_disk.w;
    float side = in.v_aux.x;
    float psi = u * 6.2831853 - u_dyn1[3].x;
    float rIn = u_shape.x;
    float rOut = u_shape.y;
    float r = mix(rIn, rOut, s);
    float lr = log(r / rIn);
    int oct = int(u_mode.w);
    // 差速旋轉（角速度 ∝ r^-1.5）的紊流；兩組相位交替（flow map），避免越捲越緊，也讓相位可以折回
    float T = 6.0;
    float c = u_dyn0[0].x / T;
    float f0 = fract(c);
    float f1 = fract(c + 0.5);
    float w = abs(2.0 * f0 - 1.0);
    float om = pow(r / rIn, -1.5);
    float sd0 = fmod(floor(c), 64.0);
    float sd1 = fmod(floor(c + 0.5), 64.0) + 64.0;
    float a0 = (psi + om * f0 * T) * 0.15915494;
    float a1 = (psi + om * f1 * T) * 0.15915494;
    float norm = rsqrt(w * w + (1.0 - w) * (1.0 - w));
    // 細紋：沿角度拉長的條紋（角向週期 12、徑向每單位 log r 40 格 → 長而細的流線）
    float n0 = bh_fbm(float2(a0 * 12.0, lr * 40.0), 12, oct, sd0);
    float n1 = bh_fbm(float2(a1 * 12.0, lr * 40.0), 12, oct, sd1);
    float n = clamp(0.5 + (mix(n0, n1, w) - 0.5) * norm, 0.0, 1.0);
    // 大尺度團塊與塵帶
    float b0 = bh_fbm(float2(a0 * 7.0, lr * 7.0 + 3.0), 7, 2, sd0 + 128.0);
    float b1 = bh_fbm(float2(a1 * 7.0, lr * 7.0 + 3.0), 7, 2, sd1 + 128.0);
    float bn = clamp(0.5 + (mix(b0, b1, w) - 0.5) * norm, 0.0, 1.0);
    float lane = smoothstep(0.58, 0.82, bn) * smoothstep(0.35, 0.65, n) * u_style.z * smoothstep(0.05, 0.3, s);
    // 起音脈衝：由內往外的亮環
    float pulse = 0.0;
    for (int k = 0; k < 4; k++) {
        float dr = (r - u_dyn0[3][k]) / (0.03 + 0.07 * s);
        pulse += u_dyn1[0][k] * exp(-dr * dr);
    }
    float spiral = 0.5 + 0.5 * cos(2.0 * psi + 9.0 * lr - u_dyn0[0].y);
    float gain = u_dyn0[1].y;
    float thick = u_dyn0[1].x;
    float inner = 1.0 - s;
    // 溫度：內緣最熱，往外冷卻；紊流與脈衝加熱
    float heat = clamp(pow(inner, 1.6) * (0.8 + 0.3 * n) + 0.6 * pulse, 0.0, 1.2);
    float3 col = heat < 0.4 ? mix(u_cool.rgb, u_mid.rgb, heat / 0.4)
                            : mix(u_mid.rgb, u_hot.rgb, clamp((heat - 0.4) / 0.45, 0.0, 1.0));
    float edgeIn = smoothstep(0.0, 0.022, s);
    float edgeOut = 1.0 - smoothstep(0.45, 1.0, s);
    float I = edgeIn * (0.3 + 4.0 * pow(inner, 2.6)) * (0.22 + 1.6 * n * sqrt(n)) * (0.8 + 0.4 * bn);
    I *= (1.0 + 0.35 * spiral * thick) * beam * gain * (1.0 + 0.3 * u_dyn0[2].z * side);
    // 脈衝：相對亮度（外圈本來較暗，脈衝經過時才看得出一圈光往外跑）
    I = I * (1.0 + 2.2 * pulse) + 0.9 * pulse * edgeOut;
    I *= u_style.x;
    // 最亮處（射束側的內緣、脈衝）才轉白，像過曝；其餘維持色相
    col = mix(col, float3(1.0), smoothstep(2.6, 4.4, I) * u_hot.w);
    // 柔和的色調曲線：亮處維持色相，不會整片截成白色；最亮處留一點給 HDR bloom
    float3 rgb = col * (1.0 - exp(-I * 1.4)) * 1.05 + u_hot.rgb * max(I - 2.6, 0.0) * 0.12;
    rgb *= 1.0 - 0.75 * lane;
    // 不透明度主要由半徑決定（條紋之間是暗色而不是透明，在淺色桌布上也看得到紋理）
    float alpha = u_style.y * edgeIn * edgeOut * (0.72 + 0.28 * n) * (0.62 + 0.38 * pow(inner, 0.7));
    alpha *= 1.0 - 0.4 * smoothstep(0.35, 0.85, s);   // 外圈較稀薄：淺色桌布上不會留下灰色的霧
    alpha = clamp(max(alpha, lane * 0.85 * edgeOut) + 0.3 * pulse * edgeOut, 0.0, 1.0);
    rgb += u_dust.rgb * lane * alpha * 0.4;
    if (u_mode.x > 1.5) {
        // 次級像：亮度隨對應程度衰減
        rgb *= weight * 1.2;
        alpha *= weight * 0.9;
    } else if (alpha < 0.03) {
        // 幾乎透明的地方不寫深度，盤後的粒子與細環才不會被看不見的盤面擋住
        discard_fragment();
    }
    BH_OUTPUT(rgb, alpha);
    """

    // MARK: - 光子環

    /// 光子環：貼著陰影的螢幕對齊細環。u_mode.y 半徑倍率、u_mode.z 寬度、u_mode.w 亮度。
    static let photonGeometry = common + arguments + """
    #pragma varyings
    float4 v_ring;
    #pragma body
    float2 uv = _geometry.texcoords[0];
    float th = uv.x * 6.2831853;
    float side = uv.y;
    float4x4 mv = scn_node.modelViewTransform;
    float3 hole = (mv * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float R = u_shape.z * u_dyn1[2].x * u_mode.y;
    float3 v = hole + float3(cos(th), sin(th), 0.0) * (R + side * u_mode.z * 0.5);
    v.z = hole.z - 0.01;
    _geometry.position = scn_node.inverseModelViewTransform * float4(v, 1.0);
    out.v_ring = float4(th, side, 0.0, 0.0);
    """

    static let photonFragment = common + arguments + """
    #pragma body
    float th = in.v_ring.x;
    float side = in.v_ring.y;
    float prof = exp(-side * side * 3.5);
    float asym = 1.0 + 0.6 * (-cos(th)) + 0.15 * sin(th);
    float glow = (0.7 + 0.5 * u_dyn0[1].y) * (1.0 + 0.9 * u_dyn0[2].y);
    float3 col = mix(u_hot.rgb, float3(1.0), 0.35 * u_hot.w);
    float3 rgb = col * prof * asym * glow * u_mode.w;
    BH_OUTPUT(rgb, prof * 0.85);
    """

    // MARK: - 細環

    /// 同心細環：頂點 position = (半徑, 傾角, 節點角)，texcoord = (u, 側)。
    /// u_mode.x 0 盤後一趟、1 盤前一趟；u_mode.y 透鏡深度衰減；u_mode.z 線寬；u_mode.w 亮度。
    static let ringGeometry = common + arguments + """
    #pragma varyings
    float4 v_ring;
    #pragma body
    float2 uv = _geometry.texcoords[0];
    float th = uv.x * 6.2831853;
    float side = uv.y;
    float3 prm = _geometry.position.xyz;
    float4x4 mv = scn_node.modelViewTransform;
    float3 hole = (mv * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float rsAngle = u_shape.z / max(-hole.z, 1e-3);
    float3 p0 = bh_ring_point(th, prm.x, prm.y, prm.z, u_dyn1[1], u_dyn0[0].w, u_dyn0[2].x);
    float3 p1 = bh_ring_point(th + 0.012, prm.x, prm.y, prm.z, u_dyn1[1], u_dyn0[0].w, u_dyn0[2].x);
    float wgt = 1.0;
    float3 v0 = bh_lens((mv * float4(p0, 1.0)).xyz, hole, u_shape.w, u_mode.y, 0.0, rsAngle, wgt);
    float3 v1 = bh_lens((mv * float4(p1, 1.0)).xyz, hole, u_shape.w, u_mode.y, 0.0, rsAngle, wgt);
    float2 sd = v1.xy / max(-v1.z, 1e-3) - v0.xy / max(-v0.z, 1e-3);
    float2 tdir = length(sd) > 1e-7 ? normalize(sd) : float2(1.0, 0.0);
    float2 nrm = float2(-tdir.y, tdir.x);
    // 線寬至少約 2 px：小視窗（尤其 LOW 沒有 MSAA）時細環不會斷成虛線；加寬時亮度與不透明度依覆蓋率降低
    float halfPx = u_mode.z * 0.5 / max(-hole.z, 1e-3) * scn_frame.projectionTransform[1][1] * 0.5
                 / max(scn_frame.inverseResolution.y, 1e-6);
    float widen = max(1.0, 1.0 / max(halfPx, 1e-3));
    v0.xy += nrm * side * u_mode.z * 0.5 * widen * (-v0.z / max(-hole.z, 1e-3));
    _geometry.position = scn_node.inverseModelViewTransform * float4(v0, 1.0);
    float left = clamp(-(v0.x / max(-v0.z, 1e-3) - hole.x / max(-hole.z, 1e-3)) * 2.0, -1.0, 1.0);
    float depth = clamp(1.0 - 0.45 * (-v0.z + hole.z), 0.45, 1.35);
    float3 camM = (scn_node.inverseModelViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float cover = bh_disk_cover(p0, camM, u_shape.x, u_shape.y);
    float vis = u_mode.x > 0.5 ? 1.0 - cover : cover;
    out.v_ring = float4(th, side, left, depth * vis / widen);
    """

    static let ringFragment = common + arguments + """
    #pragma body
    float side = in.v_ring.y;
    float prof = exp(-side * side * 2.6);
    float glow = (0.55 + 0.45 * u_dyn0[1].y + 0.8 * u_dyn0[2].x) * (1.0 + 0.35 * in.v_ring.z) * in.v_ring.w;
    float3 rgb = u_mid.rgb * prof * glow * u_mode.w;
    BH_OUTPUT(rgb, prof * u_mode.w * 0.7 * in.v_ring.w);
    """

    // MARK: - 軌道粒子流

    /// 軌道粒子（每顆是一個沿運動方向拉長的小四邊形，圓頭、尾巴漸暗）。
    /// position = (a, e, M0)、normal = (傾角, 節點, 近點角)、texcoord = (平均角速度, 雜湊)、
    /// color = (徑向偏移+0.5, 法向偏移+0.5, 亮度, 種類 + 10×角落)；種類 0 粒子流、0.5 細塵、1 火花。
    /// 位置由克卜勒方程式在這裡算出（軌道相位 u_dyn0[0].z）。
    /// u_mode.x：1 = 火花層（只在高頻火花時發亮）；u_mode.y 透鏡深度衰減；u_mode.z 0 盤後、1 盤前。
    static let particleGeometry = common + arguments + """
    #pragma varyings
    float4 v_col;
    float4 v_uv;
    #pragma body
    float3 el = _geometry.position.xyz;
    float3 orient = _geometry.normal;
    float2 tc = _geometry.texcoords[0];
    float4 at = _geometry.color;
    float corner = floor(at.w * 0.1 + 0.01);
    float kind = at.w - corner * 10.0;
    float cx = (corner > 0.5 && corner < 2.5) ? 1.0 : -1.0;
    float cy = corner > 1.5 ? 1.0 : -1.0;
    float a = el.x;
    float e = el.y;
    float M = el.z + tc.x * u_dyn0[0].z;
    float E = M;
    for (int i = 0; i < 4; i++) {
        E = E - (E - e * sin(E) - M) / (1.0 - e * cos(E));
    }
    float cE = cos(E);
    float sE = sin(E);
    float sq = sqrt(max(1.0 - e * e, 0.0));
    float X = a * (cE - e);
    float Y = a * sq * sE;
    float rad = max(length(float2(X, Y)), 1e-4);
    float2 rdir = float2(X, Y) / rad;
    float hsh = tc.y;
    float mid = u_dyn0[2].x;
    float mp = u_dyn0[0].w;
    float kick = 0.0;
    for (int k = 0; k < 4; k++) {
        float dr = (rad - u_dyn0[3][k]) / 0.12;
        kick += u_dyn1[0][k] * exp(-dr * dr);
    }
    // 中頻讓軌道起伏變形、低頻把軌道往內拉、起音脈衝經過時往外推
    float scale = 1.0 + (at.x - 0.5) + mid * 0.07 * sin(2.0 * E + mp + hsh * 6.2831853)
                - 0.035 * u_dyn0[1].x + 0.06 * kick;
    float2 q = rdir * rad * scale;
    float zOff = a * ((at.y - 0.5) + mid * 0.07 * sin(3.0 * E - 2.0 * mp + orient.y * 3.0));
    float3 p = bh_orient(float3(q.x, zOff, -q.y), orient);
    float3 tdir = normalize(bh_orient(float3(-a * sE, 0.0, -a * sq * cE), orient));
    float4x4 mv = scn_node.modelViewTransform;
    float4x4 imv = scn_node.inverseModelViewTransform;
    float3 hole = (mv * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float dh = max(-hole.z, 1e-3);
    float rsAngle = u_shape.z / dh;
    // 拖尾長度跟著軌道相位的前進速率（靜音時縮到最短）
    float len = a * tc.x * (0.07 + 0.2 * u_dyn1[2].w) * (kind > 0.25 && kind < 0.75 ? 0.4 : 1.0);
    float wgt = 1.0;
    float3 vh = bh_lens((mv * float4(p, 1.0)).xyz, hole, u_shape.w, u_mode.y, 0.0, rsAngle, wgt);
    float3 vt = bh_lens((mv * float4(p - tdir * len, 1.0)).xyz, hole, u_shape.w, u_mode.y, 0.0, rsAngle, wgt);
    float2 sh = vh.xy / max(-vh.z, 1e-3);
    float2 st = vt.xy / max(-vt.z, 1e-3);
    float2 ax = sh - st;
    float L = length(ax);
    float2 dir = L > 1e-7 ? ax / L : float2(1.0, 0.0);
    float2 perp = float2(-dir.y, dir.x);
    float size = (kind > 0.75 ? 0.011 : (kind > 0.25 ? 0.0032 : 0.0048)) / dh;
    float along = (cx + 1.0) * 0.5;
    float z = mix(vt.z, vh.z, along);
    float2 sp = mix(st, sh, along) + dir * (cx * size) + perp * (cy * size);
    _geometry.position = imv * float4(sp * -z, z, 1.0);
    // 盤後／盤前分兩趟畫：被盤面擋住的粒子先畫，讓半透明盤面蓋在上面
    float3 camM = (imv * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float cover = bh_disk_cover(p, camM, u_shape.x, u_shape.y);
    float vis = u_mode.z > 0.5 ? 1.0 - cover : cover;
    // 亮度：越靠近中心越熱、越遠離鏡頭越暗；高頻提高細塵亮度
    float dist = length(p);
    float heat = clamp(u_shape.x * 1.5 / dist, 0.35, 1.6);
    float depth = clamp(1.0 - 0.3 * (-vh.z + hole.z), 0.5, 1.3);
    float treb = u_dyn0[1].z;
    float lum = at.z * heat * depth * (0.75 + 0.35 * u_dyn0[1].y) * 1.7;
    float3 base = mix(u_mid.rgb, u_cool.rgb, hsh);
    if (kind > 0.25 && kind < 0.75) {
        lum *= 0.3 + 1.3 * treb;
        base = mix(u_cool.rgb, u_dust.rgb, 0.3 + 0.4 * hsh);
    } else {
        lum *= 0.85 + 0.45 * treb + 0.7 * kick;
        base = mix(base, u_hot.rgb, clamp(heat - 0.8, 0.0, 0.6));
    }
    if (u_mode.x > 0.5) {
        float sel = fract(hsh * 97.31 + u_dyn1[1].w * 0.6180339);
        lum = step(sel, 0.22) * u_dyn0[1].w * heat * 1.8;
        base = mix(u_hot.rgb, float3(1.0), 0.45);
    }
    // 保持黑色陰影的輪廓乾淨：在黑洞前方、落在陰影圓盤內的粒子淡出
    float2 hc = hole.xy / dh;
    float rho = length(sh - hc) / max(rsAngle, 1e-5);
    float clear = vh.z > hole.z ? smoothstep(0.92, 1.3, rho) : 1.0;
    lum *= vis * clear;
    float alpha = clamp(lum * 0.8, 0.0, 0.9);
    // 柔和的色調曲線（沒有 HDR 時也不會截成白色）
    out.v_col = float4(base * (1.0 - exp(-lum * 1.3)) * 1.15, alpha);
    float hl = L / max(2.0 * size, 1e-7);
    out.v_uv = float4(cx * (hl + 1.0), cy, hl, 0.0);
    """

    static let particleFragment = common + arguments + """
    #pragma body
    float hl = in.v_uv.z;
    float uu = in.v_uv.x;
    float d = length(float2(max(abs(uu) - hl, 0.0), in.v_uv.y));
    float shape = clamp(1.0 - d, 0.0, 1.0);
    shape *= shape;
    float head = clamp(uu / (hl + 1.0) * 0.5 + 0.5, 0.0, 1.0);
    float k = shape * mix(0.2, 1.0, head);
    BH_OUTPUT(in.v_col.rgb * k, in.v_col.a * k);
    """

    /// 建立一個使用指定 shader 的材質（不受光照、premultiplied over 混合）。
    static func material(geometry: String, fragment: String, writesDepth: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        // 一定要有半透明的 diffuse，SceneKit 才會把它放進「透明」那一趟並開啟混合（顏色本身由 fragment modifier 決定）；
        // 不透明的材質即使設 blendMode 也會直接覆寫底下的像素。
        material.diffuse.contents = translucentPixel() ?? CGColor(gray: 0, alpha: 0.5)
        material.blendMode = .alpha
        material.isDoubleSided = true
        material.writesToDepthBuffer = writesDepth
        material.readsFromDepthBuffer = true
        material.shaderModifiers = [.geometry: geometry, .fragment: fragment]
        return material
    }

    /// 1×1 半透明的貼圖。實測：純色的半透明 diffuse 會讓 SceneKit 用「材質常數」的不透明度混合（忽略 fragment 的 alpha）；
    /// 換成貼圖後才改用每個 fragment 輸出的 alpha，而且是 premultiplied 的 (one, 1−srcAlpha)。
    private static func translucentPixel() -> CGImage? {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: SceneMaterials.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
    }
}
