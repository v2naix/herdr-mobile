# Caddy + Cloudflare DNS-01 部署核对

调研日期：2026-07-16

目标：`https://herdr.example.com`（或高端口 HTTPS）经 Surge Ponte 到达 Mac loopback TLS proxy，再反向代理到 `127.0.0.1:8787`。

本文只补充 `docs/research/surge-ponte.md` 未覆盖的 Caddy、Cloudflare 与本机端口结论。

## 结论

- Caddy 的标准发行版不包含 Cloudflare DNS provider；DNS-01 自动签发需要带 `dns.providers.cloudflare` 模块的自定义构建。[caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare)
- Cloudflare 推荐使用单个 scoped API Token，仅授予目标 zone 的 `Zone.Zone:Read` 与 `Zone.DNS:Edit`。Caddyfile 应通过环境变量引用 token，不应把 token 写进配置。[caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare)
- DNS-01 不要求为 `herdr.example.com` 创建公开 A/AAAA 记录；ACME 验证依赖临时 `_acme-challenge` TXT 记录。Caddy 会自动管理证书的签发和续期。[Caddy Automatic HTTPS](https://caddyserver.com/docs/automatic-https)、[Caddy `tls` directive](https://caddyserver.com/docs/caddyfile/directives/tls)
- Caddy `reverse_proxy` 原生支持 WebSocket upgrade，不需要单独配置 Upgrade/Connection 请求头。[Caddy `reverse_proxy` directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- `bind 127.0.0.1` 可把站点 listener 限定在 IPv4 loopback；若省略，listener 默认不限于 loopback。[Caddy `bind` directive](https://caddyserver.com/docs/caddyfile/directives/bind)
- 本机当前没有进程监听 TCP 443，也没有安装 Caddy、lego、certbot 或 acme.sh；但普通用户绑定 `127.0.0.1:443` 实测得到 `PermissionError`。因此默认 443 需要特权服务或特权端口转发；无特权的低维护方案应使用例如 8443，并以 `https://herdr.example.com:8443` 访问。

## 建议 Caddyfile 形态

```caddyfile
herdr.example.com:8443 {
    bind 127.0.0.1

    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }

    reverse_proxy 127.0.0.1:8787
}
```

端口最终应按部署选择确定。若改成默认 443，不能让 root 服务执行位于用户可写仓库中的二进制或配置；二进制、配置和凭据应安装到 root 管理的位置并设置严格权限。

## 凭据边界

1. 在 Cloudflare 为 `example.com` 创建专用 API Token。
2. 权限只授予 `Zone.Zone:Read` 和 `Zone.DNS:Edit`，资源只包含 `example.com`。
3. 不在聊天、Git、Caddyfile、命令参数或日志中传递 token。
4. 本地凭据文件使用 `0600`；启动包装脚本读取后只通过环境变量交给 Caddy。
5. Caddy 官方模块 README 推荐单 token 方式；分离 Zone/DNS token 的方式已标记为 deprecated。[caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare)

## Surge 配合

继续采用 `docs/research/surge-ponte.md` 的边界：

- Mac Surge DNS Mapping：`herdr.example.com = 127.0.0.1`；
- iOS Surge 在可能触发 DNS 解析的规则之前添加 `DOMAIN,herdr.example.com,DEVICE:<PONTE_DEVICE>`；
- 不创建指向家庭公网地址的公开 A/AAAA 记录；
- herdr-mobile 使用精确 Origin（含非默认端口），并恢复默认 Secure cookie。

## 主要来源

- [Caddy Cloudflare DNS provider](https://github.com/caddy-dns/cloudflare)
- [Caddy Automatic HTTPS](https://caddyserver.com/docs/automatic-https)
- [Caddy `tls` directive](https://caddyserver.com/docs/caddyfile/directives/tls)
- [Caddy `bind` directive](https://caddyserver.com/docs/caddyfile/directives/bind)
- [Caddy `reverse_proxy` directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Cloudflare: Create API token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
