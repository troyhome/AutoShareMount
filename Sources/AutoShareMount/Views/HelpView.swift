import SwiftUI

struct HelpView: View {
    @Binding var section: Section?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Setting up takes two parts: turn on sharing on the computer that has the files, then connect from this Mac.")
                    .foregroundStyle(.secondary)

                HelpCard(symbol: "laptopcomputer", title: "1a. Share drives from another Mac", steps: [
                    "On the Mac that has the drives, open **System Settings › General › Sharing**.",
                    "Turn on **File Sharing**, then click the **ⓘ** next to it.",
                    "Under **Shared Folders**, click **+** and choose the drives or folders to share.",
                    "Keep that Mac awake: **System Settings › Battery › Options** (or **Energy**) and turn on **Wake for network access**.",
                ], note: "Macs signed in to the same Apple ID connect to each other without a password.")

                HelpCard(symbol: "pc", title: "1b. Share folders from a Windows PC", steps: [
                    "Open **Settings › Network & internet › Advanced network settings › Advanced sharing settings** and turn on **Network discovery** and **File and printer sharing** for private networks.",
                    "Make sure your network is set to **Private** (Settings › Network & internet › your Wi‑Fi or Ethernet › Private network).",
                    "Right‑click the folder or drive › **Properties › Sharing › Advanced Sharing…** › tick **Share this folder** › **OK**.",
                    "Set the PC to never sleep while plugged in: **Settings › System › Power › Screen and sleep**.",
                ], note: "When you sign in from the Mac, use your Windows account. With a Microsoft account, the user name is your Microsoft email and the password is your Microsoft password — a PIN won't work.")

                HelpCard(symbol: "magnifyingglass", title: "2. Connect from this Mac", steps: [
                    "Open **Find Drives**. Your Macs and PCs show up after a few seconds.",
                    "Click **Connect…** next to the computer.",
                    "Sign in when asked and tick **Remember this password in my keychain**.",
                    "Choose the drives you want. They're added to **My Drives** automatically and reconnect on their own from now on.",
                ], note: "Don't see the computer? Click **Connect by Address** and type its name (like CRUSHER) or its IP address.")

                Button("Go to Find Drives") { section = .find }
                    .controlSize(.large)

                HelpCard(symbol: "wrench.and.screwdriver", title: "If something doesn't connect", steps: [
                    "**“Needs your password”** — click **Sign In…** next to the drive and tick **Remember this password**.",
                    "**“Waiting for …”** — the other computer is asleep, off, or not on this network. It reconnects by itself once it's back.",
                    "**“Ejected”** — you ejected it. It comes back after the next sleep or restart, or click **Connect**.",
                    "Allow **Local Network** access for AutoShareMount in **System Settings › Privacy & Security › Local Network**.",
                ], note: nil)
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle("How to Share")
    }
}

private struct HelpCard: View {
    let symbol: String
    let title: String
    let steps: [String]
    let note: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(.init(step)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let note {
                    Label { Text(.init(note)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "lightbulb") }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: symbol).font(.headline)
        }
    }
}
