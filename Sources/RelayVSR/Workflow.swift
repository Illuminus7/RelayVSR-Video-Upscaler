import Foundation

/// The RelayVSR graph for one part of a video, in ComfyUI's API format. It is ComfyUI's
/// standard RelayVSR video upscale graph, plus a Trim Video node that selects the part:
///
///   LoadVideo -> Trim Video -> GetVideoComponents -> RelayVSRConditioning -> KSampler (1 step, cfg 1)
///                                                  -> VSRDecode -> CreateVideo -> SaveVideo
///
/// Audio is left out here; the original audio is added when the parts are joined.
enum RelayVSRWorkflow {
    static func graph(inputFileName: String, scale: Scale,
                      start: Double, duration: Double, outputPrefix: String) -> [String: Any] {
        [
            "1": node("LoadVideo", [
                "file": inputFileName,
            ]),
            "3": node("Video Slice", [
                "video": link("1", 0),
                "start_time": start,
                "duration": duration,
                "strict_duration": false,
            ]),
            "2": node("GetVideoComponents", [
                "video": link("3", 0),
            ]),
            "4": node("UNETLoader", [
                "unet_name": scale.unetFileName,
                "weight_dtype": "default",
            ]),
            "5": node("RelayVSRConditioning", [
                "model": link("4", 0),
                "images": link("2", 0),
            ]),
            "6": node("KSampler", [
                "model": link("4", 0),
                "positive": link("5", 0),
                "negative": link("5", 0),
                "latent_image": link("5", 1),
                "seed": 0,
                "steps": 1,
                "cfg": 1.0,
                "sampler_name": "euler",
                "scheduler": "simple",
                "denoise": 1.0,
            ]),
            "7": node("VAELoader", [
                "vae_name": scale.vaeFileName,
            ]),
            "104": node("VSRDecode", [
                "vae": link("7", 0),
                "samples": link("6", 0),
                "images": link("2", 0),
                "detail": 1.0,
            ]),
            "105": node("CreateVideo", [
                "images": link("104", 0),
                "fps": link("2", 2),
                "bit_depth": "auto",
                "color_space": "sRGB",
            ]),
            "106": node("SaveVideo", [
                "video": link("105", 0),
                "filename_prefix": outputPrefix,
                "format": "auto",
            ]),
        ]
    }

    private static func node(_ classType: String, _ inputs: [String: Any]) -> [String: Any] {
        ["class_type": classType, "inputs": inputs]
    }

    private static func link(_ nodeID: String, _ output: Int) -> [Any] {
        [nodeID, output]
    }
}
