# FAQs

### Where are the VMs stored?

VMs are stored in `~/.lume`.

### How are images cached?

Images are cached in `~/.lume/cache`. When doing `lume pull <image>`, it will check if the image is already cached. If not, it will download the image and cache it, removing any older versions.

### Are VM disks taking up all the disk space?

No, macOS uses sparse files, which only allocate space as needed. For example, VM disks totaling 50 GB may only use 20 GB on disk.

### How do I get the latest macOS restore image URL?

```bash
lume ipsw
```

### How do I delete a VM?

```bash
lume delete <name>
```

### How to Install macOS from an IPSW Image

#### Create a new macOS VM using the latest supported IPSW image:
Run the following command to create a new macOS virtual machine using the latest available IPSW image:

```bash
lume create <name> --os macos --ipsw latest
```

#### Create a new macOS VM using a specific IPSW image:
To create a macOS virtual machine from an older or specific IPSW file, first download the desired IPSW (UniversalMac) from a trusted source.

Then, use the downloaded IPSW path:

```bash
lume create <name> --os macos --ipsw <downloaded_ipsw_path>
```

### How do I install a custom Linux image?

The process for creating a custom Linux image differs than macOS, with IPSW restore files not being used. You need to create a linux VM first, then mount a setup image file to the VM for the first boot.

```bash
lume create <name> --os linux

lume run <name> --mount <path-to-setup-image>

lume run <name>
```
