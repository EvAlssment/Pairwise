import Darwin

enum RuntimeArchitectureDiagnostics {
    static var current: String {
        let arm64Hardware = sysctlInt("hw.optional.arm64")
        let translated = sysctlInt("sysctl.proc_translated")
        return summary(processArchitecture: processArchitecture,
                       arm64Hardware: arm64Hardware,
                       translated: translated)
    }

    static func summary(processArchitecture: String,
                        arm64Hardware: Int32?,
                        translated: Int32?) -> String
    {
        let hardware: String
        switch arm64Hardware {
        case 1: hardware = "Apple silicon"
        case 0: hardware = "Intel"
        default: hardware = "unknown hardware"
        }

        let execution: String
        if translated == 1 {
            execution = "Rosetta translated"
        } else if translated == 0 || arm64Hardware == 0 {
            execution = "native"
        } else {
            execution = "translation status unavailable"
        }
        return "\(processArchitecture) process · \(hardware) · \(execution)"
    }

    private static var processArchitecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = name.withCString { sysctlbyname($0, &value, &size, nil, 0) }
        return status == 0 ? value : nil
    }
}
