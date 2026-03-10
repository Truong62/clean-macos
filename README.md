# Clean macOS

Ứng dụng desktop (web UI chạy local) giúp anh dọn rác dev & system trên macOS: node_modules, caches, build artifacts, Docker data, Time Machine snapshots… Tất cả được gom về một bảng điều khiển để quét, lọc theo category và xoá chỉ với vài cú click.

![Clean macOS dashboard](https://cdn.shopify.com/s/files/1/0874/1643/9088/files/Screenshot_2026-03-10_at_15.14.35.png?v=1773130510)

## Tính năng chính

- 🔍 **Scan đa nguồn**: quét đường dẫn anh chỉ định + bộ sưu tập đường dẫn macOS cố định (Caches, Logs, Xcode DerivedData, Docker, Simulator, …).
- 📊 **Tổng quan dung lượng**: hiển thị tổng dung lượng máy, đã dùng, còn trống, tổng dung lượng có thể dọn.
- 🏷️ **Phân loại thông minh**: group theo `system`, `xcode`, `cache`, `docker`, `vm`, `downloads`, … để lọc nhanh.
- ✅ **Xoá an toàn**: chỉ xoá những gì không nằm trong danh sách "protected" (`/`, `/System`, thư mục Home…) và tự bỏ qua symlink.
- 🧹 **Clean trực tiếp từ UI**: chọn item → `Clean Selected`, có báo cáo số item đã xoá và dung lượng giải phóng.
- 🕰️ **Quản lý Time Machine snapshots**: liệt kê và xoá snapshot cũ (yêu cầu chạy với `sudo`).
- 🚀 **Tự mở trình duyệt**: chạy binary là mở ngay dashboard tại `http://localhost:<port>`.

## Yêu cầu

| Thành phần | Ghi chú |
|------------|---------|
| macOS 13+  | Đã test trên Apple Silicon |
| Go 1.25    | `go.mod` yêu cầu 1.25 (snapshot future). Nếu đang ở 1.22/1.23 thì dùng `brew install go@1.25` hoặc đổi `go.mod` về phiên bản đang có |
| Quyền `sudo` (optional) | Cần cho các path hệ thống: `/Library/Caches`, `/private/var/folders`, Time Machine snapshots, ... |

## Cài đặt & build

```bash
# Clone repo
mkdir -p ~/Projects && cd ~/Projects
git clone git@github.com:Truong62/clean-macos.git
cd clean-macos

# Build binary
GOOS=darwin GOARCH=arm64 go build -o clean-macos
```

> Binary `clean-macos` đã được commit sẵn để test nhanh; anh có thể build lại nếu muốn chắc chắn dùng bản local.

## Chạy ứng dụng

```bash
# Chạy mặc định (port 8080, scan từ /Users)
./clean-macos

# Tùy chỉnh
./clean-macos --port 8090 --path /Users/anhtruong/Desktop

# Nếu cần xoá các mục yêu cầu quyền root (System caches, Time Machine)
sudo ./clean-macos
```

- Khi chạy, app sẽ in địa chỉ và tự mở browser mặc định. Nếu không mở, truy cập thủ công `http://localhost:<port>`.
- Tham số `--path` giúp đặt thư mục scan mặc định (ví dụ một dự án cụ thể).

## Cách sử dụng Dashboard

1. **Scan**
   - Nhập đường dẫn (hoặc giữ mặc định) → bấm `Scan`.
   - Ứng dụng sẽ quét cả thư mục anh chọn + các fixed path macOS.
2. **Lọc & chọn**
   - Dùng thanh filter để hiển thị từng category (`system`, `cache`, `xcode`, …).
   - Tích checkbox để chọn các mục cần xoá. Mặc định "Select All" chỉ chọn các mục không cần `sudo`.
3. **Clean**
   - Bấm `Clean Selected` → xác nhận.
   - Kết quả trả về số item xoá thành công, thất bại (nếu thiếu quyền) và tổng dung lượng giải phóng.
4. **Snapshots**
   - Nếu máy có Time Machine local snapshots, bảng "Time Machine" sẽ hiện danh sách. Bấm `Delete` để xoá (nhớ chạy app bằng `sudo`).

## API nội bộ (dùng thử qua curl/Postman)

| Endpoint | Method | Mô tả |
|----------|--------|-------|
| `/api/disk` | GET | Thông tin ổ đĩa & hệ thống |
| `/api/scan` | POST | Body `{ "path": string, "maxDepth": number }` → trả về danh sách artifacts |
| `/api/clean` | POST | Body `{ "paths": string[] }` → thực thi xoá |
| `/api/snapshot/delete` | POST | Body `{ "date": string }` → xoá snapshot theo `tmutil`

## Ghi chú an toàn

- Hàm `IsSafeToDelete` bảo vệ các đường dẫn hệ thống & thư mục Home gốc.
- App bỏ qua symlink khi tính size và khi xoá.
- Một số path lớn (Docker, Simulator, Backup…) nên kiểm tra trước khi xoá hẳn.

## Phát triển thêm

- Thư mục `web/static` chứa HTML/CSS/JS thuần: có thể chuyển sang framework (React/Vue) nếu muốn mở rộng.
- `scanner/patterns.go` là nơi định nghĩa category + đường dẫn cố định. Thêm/bớt mục tại đây.
- `cleaner` lo việc tính kích thước và xoá, có thể tách log hoặc dry-run.

Chúc anh dọn rác máy Mac sạch đẹp 🔥
