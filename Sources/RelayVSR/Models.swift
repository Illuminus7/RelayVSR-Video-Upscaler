import Foundation

/// Upscale factor. Each factor uses its own checkpoint and decoder.
enum Scale: Int, CaseIterable, Identifiable {
    case x2 = 2
    case x4 = 4

    var id: Int { rawValue }
    var label: String { "×\(rawValue)" }

    var unet: ModelFile {
        switch self {
        case .x2:
            return ModelFile(folder: "diffusion_models", name: "relayvsr_x2_lightx2v_int8_convrot.safetensors",
                             knownSize: 5_163_295_248,
                             knownSHA256: "240e75e0c17cf2845d559b25254a230ff7458f81449d7a8c5e7e3fb8275c7b3c")
        case .x4:
            return ModelFile(folder: "diffusion_models", name: "relayvsr_x4_int8_convrot.safetensors",
                             knownSize: 5_164_179_952,
                             knownSHA256: "21303b3c5f9ab4e1fd3fe00df5dd2e0b343f0cf2e3d269e03a9872000a313a2e")
        }
    }

    var vae: ModelFile {
        switch self {
        case .x2:
            return ModelFile(folder: "vae", name: "relayvsr_flash_vae_x2_fp32.safetensors",
                             knownSize: 127_759_464,
                             knownSHA256: "b5bb0339acb5b52545911ea29a51b4c5b805776a779222b5a14591571f42e21c")
        case .x4:
            return ModelFile(folder: "vae", name: "relayvsr_flash_vae_x4_fp32.safetensors",
                             knownSize: 127_759_784,
                             knownSHA256: "7b8b8c99275fd5c4501b0589cc7b4c4506456a5df83160ef4e207e147b30f714")
        }
    }

    var unetFileName: String { unet.name }
    var vaeFileName: String { vae.name }

    /// Files this factor needs, laid out the way ComfyUI expects a models folder.
    var requiredFiles: [ModelFile] { [unet, vae] }
}

/// One checkpoint from https://huggingface.co/Comfy-Org/RelayVSR.
///
/// `knownSize` and `knownSHA256` are the published values when this app was built. A download
/// is checked against the hash Hugging Face reports at download time, and falls back to these.
struct ModelFile: Hashable {
    static let repoBase = "https://huggingface.co/Comfy-Org/RelayVSR/resolve/main"

    let folder: String
    let name: String
    let knownSize: Int64
    let knownSHA256: String

    var relativePath: String { "\(folder)/\(name)" }
    var remoteURL: URL { URL(string: "\(ModelFile.repoBase)/\(relativePath)")! }
    var approxSizeGB: Double { Double(knownSize) / 1_000_000_000 }

    func localURL(in modelsFolder: URL) -> URL {
        modelsFolder.appendingPathComponent(relativePath)
    }

    /// True when the file is in the folder and is not obviously truncated. The bound is loose
    /// (90%) so that a newer upstream version of the file is still accepted.
    func isPresent(in modelsFolder: URL) -> Bool {
        let path = localURL(in: modelsFolder).path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 else {
            return false
        }
        return size >= knownSize * 9 / 10
    }
}
