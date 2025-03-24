## API Reference

<details open>
<summary><strong>Create VM</strong> - POST /vms</summary>

```bash
curl --connect-timeout 6000 \
    --max-time 5000 \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{
      "name": "lume_vm",
      "os": "macOS",
      "cpu": 2,
      "memory": "4GB",
      "diskSize": "64GB",
      "display": "1024x768",
      "ipsw": "latest"
    }' \
    http://localhost:3000/lume/vms
```
</details>

<details open>
<summary><strong>Run VM</strong> - POST /vms/:name/run</summary>

```bash
# Basic run
curl --connect-timeout 6000 \
  --max-time 5000 \
  -X POST \
  http://localhost:3000/lume/vms/my-vm-name/run

# Run with VNC client started and shared directory
curl --connect-timeout 6000 \
  --max-time 5000 \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "noDisplay": false,
    "sharedDirectories": [
      {
        "hostPath": "~/Projects",
        "readOnly": false
      }
    ],
    "recoveryMode": false
  }' \
  http://localhost:3000/lume/vms/lume_vm/run
```
</details>

<details open>
<summary><strong>List VMs</strong> - GET /vms</summary>

```bash
curl --connect-timeout 6000 \
  --max-time 5000 \
  http://localhost:3000/lume/vms
```
```
[
  {
    "name": "my-vm",
    "state": "stopped",
    "os": "macOS",
    "cpu": 2,
    "memory": "4GB",
    "diskSize": "64GB"
  },
  {
    "name": "my-vm-2",
    "state": "stopped",
    "os": "linux",
    "cpu": 2,
    "memory": "4GB",
    "diskSize": "64GB"
  }
]
```
</details>

<details open>
<summary><strong>Get VM Details</strong> - GET /vms/:name</summary>

```bash
curl --connect-timeout 6000 \
  --max-time 5000 \
  http://localhost:3000/lume/vms/lume_vm\
```
```
{
  "name": "lume_vm",
  "state": "running",
  "os": "macOS",
  "cpu": 2,
  "memory": "4GB",
  "diskSize": "64GB"
}
```
</details>

<details open>
<summary><strong>Update VM Settings</strong> - PATCH /vms/:name</summary>

```bash
curl --connect-timeout 6000 \
  --max-time 5000 \
  -X PATCH \
  -H "Content-Type: application/json" \
  -d '{
    "cpu": 4,
    "memory": "8GB",
    "diskSize": "128GB"
  }' \
  http://localhost:3000/lume/vms/my-vm-name
```
</details>

<details open>
<summary><strong>Stop VM</strong> - POST /vms/:name/stop</summary>

```bash
curl --connect-timeout 6000 \
  --max-time 5000 \
  -X POST \
  http://localhost:3000/lume/vms/my-vm-name/stop
```
</details>

<details open>
<summary><strong>Delete VM</strong> - DELETE /vms/:name</summary>

```bash
curl --connect-timeout 6000 \
  --max-time 5000 \
  -X DELETE \
  http://localhost:3000/lume/vms/my-vm-name
```
</details>

<details open>
<summary><strong>Pull Image</strong> - POST /pull</summary>

```bash
curl --connect-timeout 6000 \
  --max-time 5000 \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "image": "macos-sequoia-vanilla:latest",
    "name": "my-vm-name",
    "registry": "ghcr.io",
    "organization": "trycua",
    "noCache": false
  }' \
  http://localhost:3000/lume/pull
```

```bash
curl --connect-timeout 6000 \
  --max-time 5000 \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "image": "macos-sequoia-vanilla:15.2",
    "name": "macos-sequoia-vanilla"
  }' \
  http://localhost:3000/lume/pull
```
</details>

<details open>
<summary><strong>Clone VM</strong> - POST /vms/:name/clone</summary>

```bash
curl --connect-timeout 6000 \
  --max-time 5000 \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "name": "source-vm",
    "newName": "cloned-vm"
  }' \
  http://localhost:3000/lume/vms/clone
```
</details>

<details open>
<summary><strong>Get Latest IPSW URL</strong> - GET /ipsw</summary>

```bash
curl --connect-timeout 6000 \
  --max-time 5000 \
  http://localhost:3000/lume/ipsw
```
</details>

<details open>
<summary><strong>List Images</strong> - GET /images</summary>

```bash
# List images with default organization (trycua)
curl --connect-timeout 6000 \
  --max-time 5000 \
  http://localhost:3000/lume/images
```

```json
{
  "local": [
    "macos-sequoia-xcode:latest",
    "macos-sequoia-vanilla:latest"
  ]
}
```
</details>

<details open>
<summary><strong>Prune Images</strong> - POST /lume/prune</summary>

```bash
curl --connect-timeout 6000 \
  --max-time 5000 \
  -X POST \
  http://localhost:3000/lume/prune
```
</details>
