// license:BSD-3-Clause
//
// GelShader - a custom shader for the bricks, written as a RealityKit shader
// graph (MaterialX nodes in USD, the format Reality Composer Pro saves) and
// loaded at run time with ShaderGraphMaterial.  PBR materials can't do
// view-dependent effects; a shader graph can:
//
//   reflection   the environment, strongest at grazing angles (Fresnel)
//   refraction   the environment sampled along a bent, see-through
//                direction, tinted by the glass: what's behind, through gel
//   inner glow   strongest face-on, like light scattering inside
//   bubbles      specks of cellular noise suspended in the glass
//   shimmer      a band of light rolling across the whole wall over time
//   iridescence  hue shifting with the viewing angle (silver)
//
// RealityKit's environment-radiance node returns the environment reflected
// about a given normal; feeding it the half vector between the view and the
// refracted direction makes that reflection land on the refracted direction.

import Foundation
import RealityKit
import UIKit
import os

private let log = Logger(subsystem: "org.mamedev.diorama.arkanoid", category: "gel")

@MainActor
enum GelShader {
    private(set) static var base: ShaderGraphMaterial?
    private static var cache: [UInt32: ShaderGraphMaterial] = [:]

    /// Loads the graph once; until it's loaded, GlassLook falls back to PBR.
    static func load() async {
        guard base == nil else { return }
        do {
            base = try await ShaderGraphMaterial(named: "/Root/Gel", from: Data(usda.utf8))
            log.info("gel shader loaded")
        } catch {
            log.error("gel shader failed to load: \(String(describing: error), privacy: .public)")
        }
    }

    /// The material for one brick look.
    static func material(tint c: SIMD3<Float>, glow: Float, iridescence: Float, opacity: Float, key: UInt32) -> RealityKit.Material? {
        if let m = cache[key] { return m }
        guard var m = base else { return nil }
        do {
            try m.setParameter(name: "Tint", value: .color(CGColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)))
            try m.setParameter(name: "Glow", value: .float(glow))
            try m.setParameter(name: "Iridescence", value: .float(iridescence))
            try m.setParameter(name: "Opacity", value: .float(opacity))
        } catch {
            log.error("gel parameters: \(String(describing: error), privacy: .public)")
            return nil
        }
        cache[key] = m
        return m
    }

    // MARK: - the graph

    private static func node(_ name: String, _ id: String, _ body: String) -> String {
        """
                def Shader "\(name)"
                {
                    uniform token info:id = "\(id)"
        \(body)
                }

        """
    }

    private static let g = "/Root/Gel"

    private static let usda: String = {
        var s = """
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "Root"
        {
            def Material "Gel"
            {
                color3f inputs:Tint = (1, 0.3, 0.3)
                float inputs:Glow = 0.6
                float inputs:Iridescence = 0
                float inputs:Opacity = 0.78
                token outputs:mtlx:surface.connect = <\(g)/Surface.outputs:out>

        """
        // geometry: normal, view direction, facing ratio, Fresnel
        s += node("N", "ND_normal_vector3", """
                    string inputs:space = "world"
                    float3 outputs:out
        """)
        s += node("V", "ND_realitykit_viewdirection_vector3", """
                    string inputs:space = "world"
                    float3 outputs:out
        """)
        s += node("NdV", "ND_dotproduct_vector3", """
                    float3 inputs:in1.connect = <\(g)/V.outputs:out>
                    float3 inputs:in2.connect = <\(g)/N.outputs:out>
                    float outputs:out
        """)
        s += node("Facing", "ND_clamp_float", """
                    float inputs:in.connect = <\(g)/NdV.outputs:out>
                    float inputs:low = 0
                    float inputs:high = 1
                    float outputs:out
        """)
        s += node("Edge", "ND_realitykit_oneminus_float", """
                    float inputs:in.connect = <\(g)/Facing.outputs:out>
                    float outputs:out
        """)
        s += node("Fresnel", "ND_safepower_float", """
                    float inputs:in1.connect = <\(g)/Edge.outputs:out>
                    float inputs:in2 = 3
                    float outputs:out
        """)
        // reflection
        s += node("Reflect", "ND_realitykit_environment_radiance", """
                    color3f inputs:baseColor = (1, 1, 1)
                    half inputs:metallic = 0
                    half inputs:roughness = 0.04
                    half inputs:specular = 1
                    float3 inputs:normal.connect = <\(g)/N.outputs:out>
                    color3f outputs:diffuseRadiance
                    color3f outputs:specularRadiance
        """)
        // refraction: t = normalize(-V - 0.35 N); sample about normalize(V + t)
        s += node("NegV", "ND_multiply_vector3FA", """
                    float3 inputs:in1.connect = <\(g)/V.outputs:out>
                    float inputs:in2 = -1
                    float3 outputs:out
        """)
        s += node("Bend", "ND_multiply_vector3FA", """
                    float3 inputs:in1.connect = <\(g)/N.outputs:out>
                    float inputs:in2 = -0.35
                    float3 outputs:out
        """)
        s += node("TSum", "ND_add_vector3", """
                    float3 inputs:in1.connect = <\(g)/NegV.outputs:out>
                    float3 inputs:in2.connect = <\(g)/Bend.outputs:out>
                    float3 outputs:out
        """)
        s += node("T", "ND_normalize_vector3", """
                    float3 inputs:in.connect = <\(g)/TSum.outputs:out>
                    float3 outputs:out
        """)
        s += node("HSum", "ND_add_vector3", """
                    float3 inputs:in1.connect = <\(g)/V.outputs:out>
                    float3 inputs:in2.connect = <\(g)/T.outputs:out>
                    float3 outputs:out
        """)
        s += node("H", "ND_normalize_vector3", """
                    float3 inputs:in.connect = <\(g)/HSum.outputs:out>
                    float3 outputs:out
        """)
        s += node("Through", "ND_realitykit_environment_radiance", """
                    color3f inputs:baseColor = (1, 1, 1)
                    half inputs:metallic = 0
                    half inputs:roughness = 0.22
                    half inputs:specular = 1
                    float3 inputs:normal.connect = <\(g)/H.outputs:out>
                    color3f outputs:diffuseRadiance
                    color3f outputs:specularRadiance
        """)
        // iridescence: hue from the viewing angle, drifting with time
        s += node("Time", "ND_time_float", """
                    float outputs:out
        """)
        s += node("HueDrift", "ND_multiply_float", """
                    float inputs:in1.connect = <\(g)/Time.outputs:out>
                    float inputs:in2 = 0.05
                    float outputs:out
        """)
        s += node("HueAngle", "ND_multiply_float", """
                    float inputs:in1.connect = <\(g)/Facing.outputs:out>
                    float inputs:in2 = 1.6
                    float outputs:out
        """)
        s += node("Hue", "ND_add_float", """
                    float inputs:in1.connect = <\(g)/HueAngle.outputs:out>
                    float inputs:in2.connect = <\(g)/HueDrift.outputs:out>
                    float outputs:out
        """)
        s += node("HSV", "ND_combine3_color3", """
                    float inputs:in1.connect = <\(g)/Hue.outputs:out>
                    float inputs:in2 = 0.45
                    float inputs:in3 = 1
                    color3f outputs:out
        """)
        s += node("Rainbow", "ND_hsvtorgb_color3", """
                    color3f inputs:in.connect = <\(g)/HSV.outputs:out>
                    color3f outputs:out
        """)
        s += node("Colour", "ND_mix_color3", """
                    color3f inputs:fg.connect = <\(g)/Rainbow.outputs:out>
                    color3f inputs:bg.connect = <\(g).inputs:Tint>
                    float inputs:mix.connect = <\(g).inputs:Iridescence>
                    color3f outputs:out
        """)
        // body: what's behind, tinted twice over (thick coloured glass absorbs
        // more, which keeps the colour deep against a bright room)
        s += node("Colour2", "ND_multiply_color3", """
                    color3f inputs:in1.connect = <\(g)/Colour.outputs:out>
                    color3f inputs:in2.connect = <\(g)/Colour.outputs:out>
                    color3f outputs:out
        """)
        s += node("Body", "ND_multiply_color3", """
                    color3f inputs:in1.connect = <\(g)/Through.outputs:specularRadiance>
                    color3f inputs:in2.connect = <\(g)/Colour2.outputs:out>
                    color3f outputs:out
        """)
        // inner glow, strongest face-on: Colour * Glow * (0.3 + 0.7 facing)
        s += node("GlowShape", "ND_multiply_float", """
                    float inputs:in1.connect = <\(g)/Facing.outputs:out>
                    float inputs:in2 = 0.7
                    float outputs:out
        """)
        s += node("GlowBase", "ND_add_float", """
                    float inputs:in1.connect = <\(g)/GlowShape.outputs:out>
                    float inputs:in2 = 0.3
                    float outputs:out
        """)
        s += node("GlowAmount", "ND_multiply_float", """
                    float inputs:in1.connect = <\(g)/GlowBase.outputs:out>
                    float inputs:in2.connect = <\(g).inputs:Glow>
                    float outputs:out
        """)
        // shimmer: a band rolling across the wall, sin(1.4 t + 9 x + 5 y)^8
        s += node("P", "ND_position_vector3", """
                    string inputs:space = "world"
                    float3 outputs:out
        """)
        s += node("PDot", "ND_dotproduct_vector3", """
                    float3 inputs:in1.connect = <\(g)/P.outputs:out>
                    float3 inputs:in2 = (9, 5, 3)
                    float outputs:out
        """)
        s += node("TimeScaled", "ND_multiply_float", """
                    float inputs:in1.connect = <\(g)/Time.outputs:out>
                    float inputs:in2 = 1.4
                    float outputs:out
        """)
        s += node("Phase", "ND_add_float", """
                    float inputs:in1.connect = <\(g)/PDot.outputs:out>
                    float inputs:in2.connect = <\(g)/TimeScaled.outputs:out>
                    float outputs:out
        """)
        s += node("Wave", "ND_sin_float", """
                    float inputs:in.connect = <\(g)/Phase.outputs:out>
                    float outputs:out
        """)
        s += node("WaveUp", "ND_smoothstep_float", """
                    float inputs:in.connect = <\(g)/Wave.outputs:out>
                    float inputs:low = 0.7
                    float inputs:high = 1
                    float outputs:out
        """)
        s += node("Shimmer", "ND_multiply_float", """
                    float inputs:in1.connect = <\(g)/WaveUp.outputs:out>
                    float inputs:in2 = 0.9
                    float outputs:out
        """)
        s += node("GlowTotal", "ND_add_float", """
                    float inputs:in1.connect = <\(g)/GlowAmount.outputs:out>
                    float inputs:in2.connect = <\(g)/Shimmer.outputs:out>
                    float outputs:out
        """)
        s += node("GlowColour", "ND_multiply_color3FA", """
                    color3f inputs:in1.connect = <\(g)/Colour.outputs:out>
                    float inputs:in2.connect = <\(g)/GlowTotal.outputs:out>
                    color3f outputs:out
        """)
        // bubbles: small cells of worley noise in object space
        s += node("PO", "ND_position_vector3", """
                    string inputs:space = "object"
                    float3 outputs:out
        """)
        s += node("POScaled", "ND_multiply_vector3FA", """
                    float3 inputs:in1.connect = <\(g)/PO.outputs:out>
                    float inputs:in2 = 260
                    float3 outputs:out
        """)
        s += node("Cells", "ND_worleynoise3d_float", """
                    float3 inputs:position.connect = <\(g)/POScaled.outputs:out>
                    float inputs:jitter = 1
                    float outputs:out
        """)
        s += node("Bubble", "ND_smoothstep_float", """
                    float inputs:in.connect = <\(g)/Cells.outputs:out>
                    float inputs:low = 0.16
                    float inputs:high = 0.06
                    float outputs:out
        """)
        s += node("BubbleLight", "ND_convert_float_color3", """
                    float inputs:in.connect = <\(g)/Bubble.outputs:out>
                    color3f outputs:out
        """)
        s += node("BubbleColour", "ND_multiply_color3FA", """
                    color3f inputs:in1.connect = <\(g)/BubbleLight.outputs:out>
                    float inputs:in2 = 0.55
                    color3f outputs:out
        """)
        // reflection weighted by Fresnel, with a floor so faces still gleam
        s += node("ReflAmount", "ND_add_float", """
                    float inputs:in1.connect = <\(g)/Fresnel.outputs:out>
                    float inputs:in2 = 0.06
                    float outputs:out
        """)
        s += node("ReflScaled", "ND_multiply_float", """
                    float inputs:in1.connect = <\(g)/ReflAmount.outputs:out>
                    float inputs:in2 = 1.4
                    float outputs:out
        """)
        s += node("Refl", "ND_multiply_color3FA", """
                    color3f inputs:in1.connect = <\(g)/Reflect.outputs:specularRadiance>
                    float inputs:in2.connect = <\(g)/ReflScaled.outputs:out>
                    color3f outputs:out
        """)
        s += node("Sum1", "ND_add_color3", """
                    color3f inputs:in1.connect = <\(g)/Body.outputs:out>
                    color3f inputs:in2.connect = <\(g)/GlowColour.outputs:out>
                    color3f outputs:out
        """)
        s += node("Sum2", "ND_add_color3", """
                    color3f inputs:in1.connect = <\(g)/Sum1.outputs:out>
                    color3f inputs:in2.connect = <\(g)/BubbleColour.outputs:out>
                    color3f outputs:out
        """)
        s += node("Final", "ND_add_color3", """
                    color3f inputs:in1.connect = <\(g)/Sum2.outputs:out>
                    color3f inputs:in2.connect = <\(g)/Refl.outputs:out>
                    color3f outputs:out
        """)
        // alpha: the glass's opacity, more at the edges
        s += node("EdgeAlpha", "ND_multiply_float", """
                    float inputs:in1.connect = <\(g)/Fresnel.outputs:out>
                    float inputs:in2 = 0.3
                    float outputs:out
        """)
        s += node("AlphaSum", "ND_add_float", """
                    float inputs:in1.connect = <\(g).inputs:Opacity>
                    float inputs:in2.connect = <\(g)/EdgeAlpha.outputs:out>
                    float outputs:out
        """)
        s += node("Alpha", "ND_clamp_float", """
                    float inputs:in.connect = <\(g)/AlphaSum.outputs:out>
                    float inputs:low = 0
                    float inputs:high = 1
                    float outputs:out
        """)
        s += node("Surface", "ND_realitykit_unlit_surfaceshader", """
                    bool inputs:applyPostProcessToneMap = 1
                    color3f inputs:color.connect = <\(g)/Final.outputs:out>
                    bool inputs:hasPremultipliedAlpha = 1
                    float inputs:opacity.connect = <\(g)/Alpha.outputs:out>
                    token outputs:out
        """)
        s += """
            }
        }

        """
        return s
    }()
}
