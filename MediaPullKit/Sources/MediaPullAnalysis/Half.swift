import Accelerate

/// Half-precision values stored as their bits, converted with Accelerate (Float16 is not available on every architecture).
enum Half {
    static func floats(_ source: UnsafeRawPointer, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        guard count > 0 else { return out }
        out.withUnsafeMutableBytes { dst in
            var src = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: source),
                height: 1,
                width: vImagePixelCount(count),
                rowBytes: count * 2
            )
            var d = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
            vImageConvert_Planar16FtoPlanarF(&src, &d, 0)
        }
        return out
    }

    static func bits(_ values: [Float]) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: values.count)
        guard !values.isEmpty else { return out }
        values.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: src.baseAddress),
                    height: 1,
                    width: vImagePixelCount(values.count),
                    rowBytes: values.count * 4
                )
                var d = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(values.count), rowBytes: values.count * 2)
                vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
            }
        }
        return out
    }
}
