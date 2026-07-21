import Foundation

@main
enum TouchSurfaceProbe {
    static func main() {
        guard let array = MTDeviceCreateList()?.takeRetainedValue() else {
            print("No multitouch devices returned")
            return
        }
        for device in array as [MTDevice] {
            var deviceID: UInt64 = 0
            var width: Int32 = 0
            var height: Int32 = 0
            MTDeviceGetDeviceID(device, &deviceID)
            MTDeviceGetSensorSurfaceDimensions(device, &width, &height)
            let builtIn = MTDeviceIsBuiltIn(device)
            let eligible = RemoteTouchSurface.isEligible(
                width: width, height: height, builtIn: builtIn
            )
            print(String(
                format: "id=0x%llX surface=%dx%d builtIn=%@ eligible=%@",
                deviceID, width, height,
                builtIn ? "yes" : "no",
                eligible ? "yes" : "no"
            ))
        }
    }
}
