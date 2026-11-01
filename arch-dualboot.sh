#!/usr/bin/env bash
# arch-dualboot.sh — Instalación de Arch Linux junto a Windows sin archinstall
# UEFI + GRUB (os-prober) + ext4 + sistema base sin entorno gráfico
# Ejecutar desde la ISO oficial de Arch como root.
set -euo pipefail

# ---------- utilidades ----------
r='\e[31m'; g='\e[32m'; y='\e[33m'; b='\e[1m'; n='\e[0m'
info(){ echo -e "${g}==>${n} ${b}$*${n}"; }
warn(){ echo -e "${y}[!]${n} $*"; }
die(){  echo -e "${r}[X]${n} $*" >&2; exit 1; }

ask(){ # ask VAR "pregunta" "valor_por_defecto"
  local __v="$1" __q="$2" __d="${3:-}" __a
  read -rp "$__q${__d:+ [$__d]}: " __a
  printf -v "$__v" '%s' "${__a:-$__d}"
}
ask_pass(){ # ask_pass VAR "para quién"
  local __v="$1" __p1 __p2
  while true; do
    read -rsp "Contraseña de $2: " __p1; echo
    read -rsp "Repítela: " __p2; echo
    [[ -n "$__p1" && "$__p1" == "$__p2" ]] && break
    warn "No coinciden o está vacía. Otra vez."
  done
  printf -v "$__v" '%s' "$__p1"
}
confirm(){ local a; read -rp "$1 [s/N]: " a; [[ "$a" =~ ^[sS]$ ]]; }
chr(){ arch-chroot /mnt "$@"; }

# ---------- 1. Comprobaciones previas ----------
[[ $EUID -eq 0 ]] || die "Ejecútalo como root desde la ISO de Arch."
[[ -d /sys/firmware/efi/efivars ]] || die "No has arrancado en modo UEFI."
ping -c1 -W3 archlinux.org &>/dev/null || die "Sin internet. Para wifi: iwctl"
loadkeys es
timedatectl set-ntp true

# ---------- 2. Selección de disco y particiones ----------
info "Discos disponibles:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,MOUNTPOINTS
echo
ask DISK "Disco donde está Windows (ej. /dev/nvme0n1 o /dev/sda)"
[[ -b "$DISK" ]] || die "$DISK no existe."

if confirm "¿Abrir cfdisk para crear la partición de Arch en el espacio libre? (tipo: Linux filesystem)"; then
  cfdisk "$DISK"
fi

info "Particiones de $DISK:"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL "$DISK"
echo
ask EFI_PART  "Partición EFI de Windows (FAT32, NO se formatea)"
ask ROOT_PART "Partición para Arch (SE FORMATEARÁ)"

[[ -b "$EFI_PART"  ]] || die "$EFI_PART no existe."
[[ -b "$ROOT_PART" ]] || die "$ROOT_PART no existe."
[[ "$EFI_PART" != "$ROOT_PART" ]] || die "EFI y raíz no pueden ser la misma."
[[ "$(lsblk -no FSTYPE "$EFI_PART")" == "vfat" ]] || die "$EFI_PART no es FAT32, eso no es la EFI."
case "$(lsblk -no FSTYPE "$ROOT_PART")" in
  ntfs|vfat|BitLocker) die "$ROOT_PART parece de Windows o la EFI. Abortando." ;;
esac

# ---------- 3. Datos del sistema ----------
ask HOST     "Hostname" "archlinux"
ask NEWUSER  "Nombre de usuario" "moreno"
[[ "$NEWUSER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Usuario no válido (minúsculas, números, - y _)."
ask TZONE    "Zona horaria" "Europe/Madrid"
[[ -f "/usr/share/zoneinfo/$TZONE" ]] || die "Zona horaria no válida."
ask SWAP_GB  "Tamaño del swapfile en GB (0 = sin swap)" "4"
[[ "$SWAP_GB" =~ ^[0-9]+$ ]] || die "El swap tiene que ser un número."
ask_pass ROOT_PASS "root"
ask_pass USER_PASS "$NEWUSER"

grep -q GenuineIntel /proc/cpuinfo && UCODE=intel-ucode || UCODE=amd-ucode

# ---------- 4. Resumen ----------
echo
info "Resumen:"
cat <<EOF
  Disco:       $DISK
  EFI:         $EFI_PART  (se monta en /boot/efi, no se formatea)
  Raíz:        $ROOT_PART (ext4, SE BORRA)
  Hostname:    $HOST
  Usuario:     $NEWUSER (grupo wheel, sudo)
  Zona:        $TZONE
  Swapfile:    ${SWAP_GB}G
  Microcódigo: $UCODE
EOF
read -rp "Escribe SI en mayúsculas para continuar: " OK
[[ "$OK" == "SI" ]] || die "Cancelado."

# ---------- 5. Formateo y montaje ----------
info "Formateando $ROOT_PART..."
mkfs.ext4 -F "$ROOT_PART"
mount "$ROOT_PART" /mnt
mount --mkdir "$EFI_PART" /mnt/boot/efi

# ---------- 6. Sistema base ----------
info "Instalando paquetes base..."
pacstrap -K /mnt base base-devel linux linux-firmware linux-headers "$UCODE" \
  networkmanager sudo nano vim git man-db man-pages bash-completion \
  grub efibootmgr os-prober ntfs-3g dosfstools

genfstab -U /mnt >> /mnt/etc/fstab

if (( SWAP_GB > 0 )); then
  info "Creando swapfile de ${SWAP_GB}G..."
  chr mkswap -U clear --size "${SWAP_GB}G" --file /swapfile
  echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab
fi

# ---------- 7. Configuración ----------
info "Configurando el sistema..."
chr ln -sf "/usr/share/zoneinfo/$TZONE" /etc/localtime
chr hwclock --systohc

sed -i 's/^#\(es_ES.UTF-8 UTF-8\)/\1/; s/^#\(en_US.UTF-8 UTF-8\)/\1/' /mnt/etc/locale.gen
chr locale-gen
echo "LANG=es_ES.UTF-8" > /mnt/etc/locale.conf
echo "KEYMAP=es"        > /mnt/etc/vconsole.conf

echo "$HOST" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST.localdomain $HOST
EOF

# Usuarios (las contraseñas se pasan por stdin, no se expanden en ningún heredoc)
chr useradd -m -G wheel -s /bin/bash "$NEWUSER"
printf 'root:%s\n%s:%s\n' "$ROOT_PASS" "$NEWUSER" "$USER_PASS" | chr chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /mnt/etc/sudoers.d/wheel
chmod 440 /mnt/etc/sudoers.d/wheel

chr systemctl enable NetworkManager fstrim.timer

# ---------- 8. GRUB + os-prober ----------
info "Instalando GRUB..."
if grep -q '^#\?GRUB_DISABLE_OS_PROBER' /mnt/etc/default/grub; then
  sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /mnt/etc/default/grub
else
  echo 'GRUB_DISABLE_OS_PROBER=false' >> /mnt/etc/default/grub
fi

chr grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
chr grub-mkconfig -o /boot/grub/grub.cfg

if grep -qi windows /mnt/boot/grub/grub.cfg; then
  info "Windows detectado en el menú de GRUB."
else
  warn "No se ha detectado Windows. Tras arrancar Arch ejecuta:"
  warn "  sudo grub-mkconfig -o /boot/grub/grub.cfg"
fi

# ---------- 9. Fin ----------
umount -R /mnt
info "Instalación terminada."
if confirm "¿Reiniciar ahora? (quita el USB)"; then
  reboot
fi
