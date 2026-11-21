import SwiftUI

struct DevicePhotoView: View {
    var body: some View {
        Image("MiBox")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityLabel("密盒")
    }
}
