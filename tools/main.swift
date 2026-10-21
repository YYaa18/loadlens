import Foundation

let cpuSampler = CPUSampler()
let tracker = ProcessTracker()

_ = cpuSampler.sample()
_ = tracker.scan()
Thread.sleep(forTimeInterval: 1.0)

let totalCPU = cpuSampler.sample()
let memory = readMemoryStats()
let loads = readLoadAverage()
let samples = tracker.scan().sorted { $0.cpu > $1.cpu }

print(String(format: "overall CPU: %.1f%%   load: %.2f %.2f %.2f", totalCPU, loads.0, loads.1, loads.2))
print(String(format: "memory: %.1f/%.1f GB   swap: %.1f/%.1f GB   compressed: %.1f GB",
             Double(memory.usedBytes) / 1e9,
             Double(memory.totalBytes) / 1e9,
             Double(memory.swapUsedBytes) / 1e9,
             Double(memory.swapTotalBytes) / 1e9,
             Double(memory.compressedBytes) / 1e9))
print("thermal: \(readThermalState().rawValue)  uptime: \(Int(readSystemUptime() / 86400)) days")
print("--- top 12 processes ---")
for sample in samples.prefix(12) {
    let mb = Double(sample.rss) / 1024 / 1024
    print(String(format: "%7d  %6.1f%%  %7.0f MB  %@", sample.pid, sample.cpu, mb, sample.name))
}
