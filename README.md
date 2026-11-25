# Codex Account Switcher (Windows Portable)

Công cụ PowerShell gọn nhẹ cho Windows giúp **quản lý và chuyển đổi nhiều tài khoản OpenAI Codex CLI (`acc1..accN`)** mà **giữ nguyên toàn bộ lịch sử hội thoại** trong `%USERPROFILE%\.codex`.

## Cơ chế hoạt động

- Toàn bộ lịch sử chat, cài đặt và sessions nằm cố định tại ghế chính: `%USERPROFILE%\.codex`.
- Mỗi tài khoản chỉ lưu riêng 1 file token trong thư mục cục bộ: `%USERPROFILE%\.codex-auth-vault\auth.<slot>.json`.
- Khi chuyển tài khoản, script tự động:
  1. Kiểm tra không có cửa sổ Codex tương tác nào đang mở (tránh hỏng refresh token).
  2. Sao lưu lại `auth.json` mới nhất của tài khoản đang rời đi về vault.
  3. Nạp `auth.<slot>.json` của tài khoản đích vào `%USERPROFILE%\.codex\auth.json` và cập nhật `seat-account.txt`.

## Yêu cầu

- Windows 10 / 11 (PowerShell 5.1 trở lên, có sẵn trên Windows).
- Đã cài **OpenAI Codex CLI** (`codex` chạy được trong terminal).

## Cài đặt nhanh (3 bước)

1. Tải repo này về (bấm **Code → Download ZIP** hoặc `git clone`) và giải nén vào một thư mục cố định trên máy (ví dụ `C:\Tools\codex-account-switcher`).
2. Chạy double-click file **`Tao-Shortcut-Desktop.bat`**.
   - Script tự gỡ khóa file tải từ mạng, tạo shortcut **`Switch Codex Account`** ngoài Desktop, và nếu máy đã đăng nhập sẵn Codex thì tự lưu tài khoản hiện tại thành `acc1`.
3. Mở shortcut **`Switch Codex Account`** ngoài Desktop để sử dụng.

## Các chức năng trong Menu

| Phím | Chức năng |
| :--- | :--- |
| `[1..N]` | Chuyển ghế chính sang tài khoản tương ứng (xem trước `-DryRun` rồi mới xác nhận) |
| `[S]` | Kiểm tra quota `/status` (5h / 7d, giờ reset, loại gói) cho 1 tài khoản hoặc tất cả |
| `[A]` | Thêm tài khoản mới bằng trình duyệt mặc định |
| `[D]` | Thêm tài khoản mới bằng **device-auth** (khuyên dùng: copy link + mã dán vào **tab Ẩn danh** để đăng nhập nhiều email không bị dính cookie) |
| `[L]` | Đăng nhập lại / làm mới token / hoặc đè tài khoản Plus mới lên 1 slot cũ đã hết hạn |
| `[X]` | Xóa 1 tài khoản không còn dùng khỏi vault (tự chặn xóa tài khoản đang active, không ảnh hưởng lịch sử chat) |
| `[R]` | Làm mới trạng thái |
| `[Q]` | Thoát |

> Tên hiển thị trong menu tự động lấy phần **trước dấu `@`** của email trong `auth.json`. Nếu muốn đặt tên riêng thủ công, sửa biến `$CustomLabels` ở đầu file `switch-codex-menu.ps1`.

## Dùng trực tiếp bằng dòng lệnh (tùy chọn)

```powershell
# Khởi tạo vault từ ~/.codex/auth.json hiện có thành acc1
.\switch-codex-account.ps1 -Init

# Xem trạng thái ghế chính & danh sách slot trong vault
.\switch-codex-account.ps1 -Status

# Xem quota 5h / 7d cho toàn bộ tài khoản (hoặc 1 slot cụ thể)
.\switch-codex-account.ps1 -Quota all
.\switch-codex-account.ps1 -Quota acc2

# Thêm tài khoản mới (khuyên dùng -DeviceAuth + tab Ẩn danh)
.\switch-codex-account.ps1 -Login acc2 -DeviceAuth

# Thay thế / đăng nhập lại cho slot đã có
.\switch-codex-account.ps1 -Login acc2 -Overwrite -DeviceAuth

# Xem trước và chuyển tài khoản
.\switch-codex-account.ps1 -To acc2 -DryRun
.\switch-codex-account.ps1 -To acc2

# Xem trước và xóa tài khoản không active khỏi vault
.\switch-codex-account.ps1 -Remove acc3 -DryRun
.\switch-codex-account.ps1 -Remove acc3
```

## Lưu ý bảo mật & vận hành

- **Thoát hết cửa sổ Codex CLI đang mở** trước khi chuyển tài khoản (các tiến trình chạy nền như `app-server` của desktop app / VS Code có thể giữ nguyên).
- **Tuyệt đối không chia sẻ** thư mục `%USERPROFILE%\.codex-auth-vault` hay file `%USERPROFILE%\.codex\auth.json` cho người khác — đây là credential đăng nhập trực tiếp tài khoản của bạn.
- Không di chuyển hoặc xóa thư mục chứa script sau khi tạo shortcut (nếu đổi chỗ, chỉ cần chạy lại `Tao-Shortcut-Desktop.bat`).
