# MikroTik CHR on QEMU (Debian 12) — Installer & Injector (Indonesia)

**Repository contains:**  
- `install-chr-qemu-debian12.sh` — Full auto installer (QEMU + bridge NAT + port-forwarding + first-boot injector).  
- `force-inject.sh` — Robust injector to push MikroTik commands to CHR via QEMU serial (jika diperlukan).

Versi: **v2.2**  
Penulis: **EKO SULISTYAWAN** (dengan bantuan ChatGPT GPT-5)

---

## Deskripsi singkat
Script ini otomatis menginstal dan menjalankan **MikroTik CHR** (RouterOS) sebagai VM QEMU pada server Debian 12. Fitur penting:
- Membuat `bridge-nat` internal (`10.92.68.1/28`) untuk CHR.
- Membuat disk persistent `chr-disk.qcow2`.
- Menjalankan CHR via QEMU headless (`-nographic`) sebagai `systemd` service (`chr.service`).
- Menambahkan aturan `iptables` DNAT agar layanan CHR (Winbox/SSH/Web/API) dapat diakses lewat IP publik VPS.
- **First-boot injector** (via serial/telnet + `socat`) untuk otomatis men-set IP (`10.92.68.2/28`) di CHR dan meng-enable layanan penting sehingga tidak perlu konfigurasi manual pada install pertama.

---

## Prasyarat (Prerequisites)
- VPS/Server dengan **Debian 12** (root access).  
- Akses SSH root.  
- Koneksi internet pada server untuk mengunduh image CHR.  
- Ruang disk minimal ~200 MB kosong (lebih besar jika image berubah).

---

## File yang ada
- `install-chr-qemu-debian12.sh` — installer utama (chmod +x lalu jalankan).  
- `force-inject.sh` — injector manual (jalankan jika installer gagal inject otomatis).  
- `README.md` — dokumentasi ini.

---

## Cara instal (Langkah demi langkah)

> **Catatan:** Dianjurkan menjalankan di dalam `screen` atau `tmux` agar proses tetap berjalan saat SSH terputus.
```bash
apt update -y
apt install -y screen
screen -S chrinstall
```

1. Upload `install-chr-qemu-debian12.sh` ke server (atau clone repo), lalu jalankan:
```bash
chmod +x install-chr-qemu-debian12.sh
sudo bash install-chr-qemu-debian12.sh
```

2. Installer akan melakukan:
   - Install paket yang dibutuhkan (`qemu`, `socat`, `iptables`, dll).
   - Membuat folder `/root/chr` dan mengunduh CHR image.
   - Membuat bridge `bridge-nat` dan `tap0`.
   - Membuat systemd unit `/etc/systemd/system/chr.service`.
   - Menambahkan aturan DNAT agar port 22,80,443,8291,8728,8729 diteruskan ke CHR (`10.92.68.2`).
   - Menjalankan first-boot injector untuk memasukkan konfigurasi dasar ke CHR (auto IP dan enable service).

3. Setelah selesai, periksa status:
```bash
bash /root/chr/status.sh
```

4. Cek network dan ping CHR:
```bash
ip addr show bridge-nat
ip addr show tap0
ping -c3 10.92.68.2
```

5. Akses CHR dari komputer lokal:
- **Winbox:** `IP_PUBLIK_VPS:8291`  
- **SSH ke CHR:** `ssh admin@IP_PUBLIK_VPS -p 22`  
- **WebFig:** `http://IP_PUBLIK_VPS/`  
- **API:** `IP_PUBLIK_VPS:8728` (API-SSL: `8729`)

---

## Jika first-boot injector gagal (manual)
Kadang injector otomatis gagal (timing, image, atau serial tidak responsif). Lakukan langkah ini:

1. Pastikan service `chr` dimatikan:
```bash
systemctl stop chr
pkill -9 qemu-system-x86_64 2>/dev/null || true
```

2. Jalankan injector manual (sudah tersedia):
```bash
chmod +x force-inject.sh
bash force-inject.sh
```

3. Setelah injector selesai, restart service:
```bash
systemctl restart chr
sleep 5
bash /root/chr/status.sh
ping -c3 10.92.68.2
```

4. Jika masih belum tampil, jalankan QEMU manual agar masuk console:
```bash
bash /root/chr/run-chr.sh
# amati output, login: admin (kosong password), jalankan:
# /ip address add address=10.92.68.2/28 interface=ether1
# /ip route add gateway=10.92.68.1
# /ip service enable winbox
# lalu keluar (Ctrl+A X jika menggunakan screen)
```

---

## Troubleshooting umum

### 1. `Service: Inactive`
Lihat log systemd:
```bash
journalctl -u chr -n 200 --no-pager
```
Periksa error terkait `qemu`, `tap`, atau permission `/dev/net/tun`.

### 2. `Destination Host Unreachable` saat ping 10.92.68.2
- Pastikan CHR sudah memiliki IP di ether1 (`/ip address print` lewat console).
- Jika belum, gunakan injector atau tambahkan IP manual via console.

### 3. DNAT / Port-forwarding tidak bekerja
Lihat aturan NAT:
```bash
iptables -t nat -L PREROUTING -n
iptables -t nat -L POSTROUTING -n
```
Pastikan ada rule yang meneruskan port publik ke `10.92.68.2`.

### 4. Injector timeout
- Naikkan timeout pada `force-inject.sh` (ganti `TIMEOUT=120`) atau tambah `sleep` sebelum pengiriman.
- Pastikan `socat` terinstall.

---

## Keamanan & Catatan penting
- Default user `admin` pada RouterOS **tanpa password**. Setelah akses pertama, **segera set password**:
```mikrotik
/user set 0 password=KatasandiBaru
```
- Jika tidak memerlukan akses publik ke semua port, batasi DNAT/port-forwarding di host atau gunakan firewall CHR.
- Hapus atau ubah aturan DNAT jika ingin menonaktifkan akses publik.

---

## Menonaktifkan / Menghapus instalasi
Untuk menghapus installan dan membersihkan sistem:
```bash
systemctl stop chr
systemctl disable chr
pkill -9 qemu-system-x86_64
rm -rf /root/chr
rm -f /etc/systemd/system/chr.service
systemctl daemon-reload
# hapus bridge/tap dan aturan NAT (opsional)
ip link set tap0 down 2>/dev/null || true
brctl delif bridge-nat tap0 2>/dev/null || true
ip tuntap del dev tap0 mode tap 2>/dev/null || true
ip link set bridge-nat down 2>/dev/null || true
brctl delbr bridge-nat 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 10.92.68.0/28 -j MASQUERADE 2>/dev/null || true
for p in 22 80 443 8291 8728 8729; do
  iptables -t nat -D PREROUTING -p tcp --dport $p -j DNAT --to-destination 10.92.68.2:$p 2>/dev/null || true
done
netfilter-persistent save 2>/dev/null || true
```

---

## Lisensi
Gunakan sesuai kebutuhan. Tidak ada lisensi eksplisit — jika ingin, tambahkan `LICENSE` di repo (mis. MIT).

---
