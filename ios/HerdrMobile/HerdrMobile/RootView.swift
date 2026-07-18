import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            switch model.state.screen {
            case .setup:
                SetupView(model: model)
            case .configured:
                ConfiguredView(model: model)
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { model.pendingConfirmation != nil },
                set: { if !$0 { model.cancelDestructiveAction() } }
            ),
            titleVisibility: .visible
        ) {
            Button(confirmationButtonTitle, role: .destructive) {
                Task { await model.confirmDestructiveAction() }
            }
            Button("取消", role: .cancel) {
                model.cancelDestructiveAction()
            }
        } message: {
            Text("将撤销当前会话，并从此设备删除服务器地址和令牌。即使服务器不可达，本地数据也会清除。")
        }
    }

    private var confirmationTitle: String {
        model.pendingConfirmation == .replaceServer ? "更换服务器？" : "退出登录？"
    }

    private var confirmationButtonTitle: String {
        model.pendingConfirmation == .replaceServer ? "清除并更换" : "退出并清除"
    }
}

private struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("受信任的 Mac") {
                TextField(
                    "https://mac.example.ts.net",
                    text: Binding(
                        get: { model.state.origin },
                        set: model.updateOrigin
                    )
                )
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()

                SecureField(
                    "Bootstrap token",
                    text: Binding(
                        get: { model.state.token },
                        set: model.updateToken
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } footer: {
                Text("仅接受通过系统证书验证的 HTTPS 地址。令牌会绑定到本机设备密码，不会同步到其他设备。")
            }

            if let error = model.state.error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("setup-error")
                }
            }

            Section {
                Button {
                    let origin = model.state.origin
                    let token = model.state.token
                    Task { await model.submitSetup(origin: origin, token: token) }
                } label: {
                    if model.state.isWorking {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("验证并保存")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(model.state.isWorking)
            }
        }
        .navigationTitle("设置 Herdr Mobile")
    }
}

private struct ConfiguredView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("服务器已配置", systemImage: "checkmark.shield")
        } description: {
            Text(model.state.origin)
        } actions: {
            Text("实时 pane 浏览将在下一阶段启用。")
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Herdr Mobile")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("更换服务器", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                        model.requestServerReplacement()
                    }
                    Button("退出登录", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        model.requestLogout()
                    }
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
    }
}
