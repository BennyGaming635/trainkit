import SwiftUI

struct WhatsNewView: View {
    let continueAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "train.side.front.car")
                .font(.system(size: 54))
                .foregroundStyle(.blue)
                .padding(.bottom, 18)
            Text("What’s New in TrainKit")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.bottom, 36)

            VStack(alignment: .leading, spacing: 28) {
                feature("point.3.connected.trianglepath.dotted", "Locomotive Profiles", "Name each SBrick and configure its ports independently.")
                feature("link", "Run a Consist", "Select several locomotives and control them together.")
                feature("light.beacon.max.fill", "Safer Control", "Test ports, assign directional lights, and choose what happens if a connection is lost.")
            }
            .frame(maxWidth: 520)
            Spacer()

            Button(action: continueAction) {
                Text("Continue").frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}
