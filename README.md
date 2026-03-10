# Clean macOS

![Dashboard](https://cdn.shopify.com/s/files/1/0874/1643/9088/files/Screenshot_2026-03-10_at_15.14.35.png?v=1773130510)

> Requires Go 1.25+ on macOS.

```bash
# run directly
GOOS=darwin GOARCH=arm64 go run main.go --path /Users/you --port 8080

# or build a binary
GOOS=darwin GOARCH=arm64 go build -o clean-macos
./clean-macos --path /Users/you
```
