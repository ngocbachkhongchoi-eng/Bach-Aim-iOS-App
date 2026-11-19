# bigvip — máy chủ tài khoản

## Trạng thái
Mã nguồn server và app đã nối với API thật. Chưa triển khai server công khai: không có tài khoản cloud, domain hay VPS trong phiên làm việc. IPA không chứa tài khoản đăng nhập cục bộ hoặc mật khẩu Admin. Trước khi triển khai, màn đăng nhập sẽ báo chưa cấu hình máy chủ.

## Chạy server
Cần Node.js 24 trở lên hoặc Docker, ổ đĩa bền vững cho SQLite và HTTPS.
Đặt biến môi trường:
- BIGVIP_ADMIN_USERNAME=DfnA0hqi751
- BIGVIP_ADMIN_PASSWORD: nhập mật khẩu Admin bạn đã chọn, chỉ trên server. Không đưa vào GitHub, IPA hoặc file cấu hình công khai.
- BIGVIP_DB=/data/bigvip.sqlite
- HOST=0.0.0.0 nếu chạy sau reverse proxy trong container.
- PORT=8080
- BIGVIP_TRUSTED_PROXIES: chỉ địa chỉ IP của reverse proxy thực sự. Để trống nếu không có proxy. Proxy phải ghi đè X-Real-IP bằng địa chỉ kết nối, không tin header của khách.

Chạy `npm test`, sau đó `npm start`. Admin chỉ được tạo lần đầu khi database chưa có Admin. Đổi biến mật khẩu sau đó không đổi tài khoản đã lưu. Không có API đăng ký công khai.

Trong app: bánh răng tại trang đăng nhập → Máy chủ → URL HTTPS của server (ví dụ https://api.ten-mien-cua-ban). Dùng cùng URL trên máy Admin và máy khách. Đăng nhập Admin → tạo khách → cộng thời gian. Khách mới có 0 giờ; đúng mật khẩu vẫn bị chặn cho đến khi được cấp giờ.

## Docker + HTTPS
File compose.yaml kèm Caddy; cần một domain đã trỏ tới server và mở cổng 80/443. Tạo file .env *trên server*, không commit:
```
BIGVIP_DOMAIN=api.ten-mien-cua-ban
BIGVIP_ADMIN_USERNAME=DfnA0hqi751
BIGVIP_ADMIN_PASSWORD=<mật khẩu riêng của bạn>
```
Chạy `docker compose up -d --build`. Sao lưu volume bigvip-data thường xuyên.
Không triển khai SQLite lên ổ tạm mất dữ liệu khi dịch vụ khởi động lại. Không đưa database ra thư mục phục vụ web.

## Hành vi đã triển khai
- Mật khẩu lưu bằng scrypt có salt ngẫu nhiên; API không trả mật khẩu/hash.
- Phiên đăng nhập token ngẫu nhiên, chỉ lưu hash trên server; token trên iPhone được lưu Keychain.
- Kiểm tra vai trò Admin ở server. Khách không tự tạo tài khoản hoặc cộng thời gian.
- Giờ/ngày: thời lượng cố định; tháng/năm: lịch UTC, chặn tràn ngày cuối tháng.
- Cộng từ thời điểm lớn hơn giữa hiện tại và hạn cũ; có lựa chọn vĩnh viễn.
- Mỗi lần cộng có mã chống cộng trùng khi thử lại cùng yêu cầu.
- Khóa khách thu hồi phiên đăng nhập; tài khoản đã hết giờ bị API từ chối.
- Đếm ngược dùng thời gian server + thời gian máy hoạt động, không lấy đồng hồ chỉnh tay làm thời hạn. App xác minh lại khi trở về foreground và mỗi 30 giây.
- Màn IP hiển thị IP server quan sát được; với VPN/NAT đây là IP thoát mạng, không phải vị trí vật lý.
- Bộ mới: 10 ngôn ngữ cho đăng nhập, Admin, Cài đặt và trang chủ. Công cụ 3105 nâng cao vẫn theo các bản dịch gốc (Việt/Anh/Trung).
- Giao diện không thể đảm bảo chống sửa IPA tuyệt đối. Mã nguồn đã công khai theo yêu cầu. Quyền Admin và số giờ thực được bảo vệ trên server, không phải bằng mật khẩu nhúng vào app.
- Thời hạn kiểm soát quyền vào app và thao tác mới; không tự xóa thay đổi file game khi app đã tắt.

## Aim / ESP và nhập file
Logo và file cache do người dùng cung cấp đã kèm trong app. Chọn FF → Aim → Duyệt file → nhấn giữ đúng file cache trong dữ liệu game → Chọn làm file cache Aim Neck. Chọn một lần; bật để thay, tắt để khôi phục bản sao.
Không suy đoán đường dẫn cache, không ghi file khi chưa biết đích. Hiệu quả Aim Neck và quyền truy cập iOS chưa kiểm chứng trên thiết bị.
ESP chưa có mô-đun hiển thị người chơi.
File cache thô không phải gói .3105. Nhập .3105 phải là gói do bộ mã hóa 3105 hỗ trợ; file cache dùng làm dữ liệu thay thế.
Luồng nhập giữ bản sao riêng trước khi đóng trình chọn, xử lý sau khi sheet đóng và hiện kết quả ngay trên màn quản lý patch.

## Kiểm thử
`node --test server.test.mjs` kiểm tra đăng nhập, hết hạn, cấp giờ, vĩnh viễn, quyền Admin, thu hồi phiên, chống cộng trùng, ngày cuối tháng, giới hạn thử mật khẩu và không tin IP giả.
Script macOS `scripts/test-document-import.py` chạy trực tiếp hàm nhập file: byte nhị phân, Unicode, trùng tên, nguồn đã bị xóa, file thiếu, thư mục, symlink.
Không có thiết bị iPhone để xác minh ESign, sandbox game, thay cache hoặc hiệu quả trong game.

Tham khảo API chính thức: [Node SQLite](https://nodejs.org/api/sqlite.html), [Node Crypto](https://nodejs.org/api/crypto.html).
