# arch-dualboot

Instalación de Arch Linux junto a Windows (UEFI + GRUB + ext4), sin archinstall.

Desde la ISO de Arch, como root:

```bash
curl -LO https://raw.githubusercontent.com/morneeo/arch-dualboot/main/arch-dualboot.sh
bash arch-dualboot.sh
```

> No uses `curl ... | bash`: el script hace preguntas con `read` y necesita el teclado como entrada.
