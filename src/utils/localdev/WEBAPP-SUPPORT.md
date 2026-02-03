# Webapp Support in LocalDev

## Overview

The localdev.py tool now supports two types of applications:
1. **springboot** - Java Spring Boot applications (JAR files)
2. **webapp** - Static web applications served by nginx (Angular, React, etc.)

## How It Works

### SpringBoot Apps (e.g., ph-ee-connector-channel)

For SpringBoot apps, the localdev patcher:
1. ✅ Overrides the container image to use JDK (e.g., `eclipse-temurin:17`)
2. ✅ Adds `command: ["java", "-jar", "/app/build/libs/your-app.jar"]`
3. ✅ Adds volumeMount: `/app`
4. ✅ Adds hostPath volume pointing to your local project directory
5. ✅ Protects deployment.yaml from git commits

**Example configuration:**
```ini
[channel]
directory = ${gazelle-home}/repos/ph_template/helm/ph-ee-engine/connector-channel
image = eclipse-temurin:17
app_type = springboot
jarpath = /app/build/libs/ph-ee-connector-channel-2.0.0.mifos-SNAPSHOT.jar
hostpath = ${HOME}/ph-ee-connector-channel
```

**Workflow:**
```bash
# 1. Checkout repo and patch deployment
./localdev.py --setup --component channel

# 2. Build your JAR
cd ~/ph-ee-connector-channel
./gradlew clean build -x test

# 3. Restart pod
kubectl delete pod -n paymenthub -l app=ph-ee-connector-channel

# 4. Pod now runs with your local code!
```

### Webapp Apps (e.g., ph-ee-operations-web)

For webapp apps, the localdev patcher:
1. ✅ Checks out the repository
2. ⏭️  **SKIPS** deployment patching (no changes to deployment.yaml)
3. 💡 User configures hostPath mounts via `config/ph_values.yaml`

**Why skip patching for webapps?**
- Webapps require additional configuration (nginx config, mount paths, subpaths)
- Values.yaml provides fine-grained control over volumeMounts
- Avoids conflicts with existing volumeMounts (e.g., `/usr/share/nginx/html`)
- Keeps deployment.yaml clean and maintainable

**Example configuration:**
```ini
[operations-web]
directory = ${gazelle-home}/repos/ph_template/helm/ph-ee-engine/operations-web
app_type = webapp
hostpath = ${HOME}/ph-ee-operations-web/dist
checkout_enabled = true
reponame = https://github.com/openMF/ph-ee-operations-web
branch_or_tag = mifos-v2.0.0
```

**Workflow:**
```bash
# 1. Checkout repo only (no deployment patching)
./localdev.py --checkout --component operations-web

# 2. Configure hostPath in config/ph_values.yaml
# (See example below)

# 3. Build your webapp
cd ~/ph-ee-operations-web
npm install
npm run build

# 4. Deploy with helm
cd ~/mifos-gazelle
helm upgrade -n paymenthub phee ./repos/ph_template/helm/gazelle \
  -f config/ph_values.yaml

# 5. Webapp now serves from your local build!
```

## Configuring Webapps via values.yaml

Add this to your `config/ph_values.yaml`:

```yaml
operations-web:
  enabled: true
  image: docker.io/openmf/ph-ee-operations-web:gazelle-v1.1.0
  deployment:
    extraVolumeMounts:
      - name: nginx-spa-config
        mountPath: /etc/nginx/conf.d/default.conf
        subPath: default.conf
      - name: ops-web-dist
        mountPath: /usr/share/nginx/html
    extraVolumes:
      - name: nginx-spa-config
        configMap:
          name: nginx-spa-config
      - name: ops-web-dist
        hostPath:
          path: /home/tdaly/ph-ee-operations-web/dist/web-app
          type: Directory
```

**Key points:**
- `ops-web-dist` is mounted to `/usr/share/nginx/html` (nginx's default html directory)
- `path` points to your local built webapp (usually `dist/` or `dist/web-app/`)
- `nginx-spa-config` provides custom nginx config for SPA routing

## Directory Structure Examples

### SpringBoot App
```
~/ph-ee-connector-channel/
├── src/
├── build/
│   └── libs/
│       └── ph-ee-connector-channel-2.0.0.mifos-SNAPSHOT.jar  ← mounted at /app/
├── build.gradle
└── gradlew
```

### Webapp App
```
~/ph-ee-operations-web/
├── src/
├── dist/
│   └── web-app/            ← mounted at /usr/share/nginx/html/
│       ├── index.html
│       ├── assets/
│       └── *.js
├── angular.json
└── package.json
```

## Common Operations

### Check Status
```bash
./localdev.py --status
```

Output:
```
📦 channel
  ✅ Repository: /home/tdaly/ph-ee-connector-channel
     Branch: mifos-v2.0.0
  🔒 Deployment patched and protected

📦 operations-web
  ✅ Repository: /home/tdaly/ph-ee-operations-web
     Branch: mifos-v2.0.0
  ℹ️  Deployment not patched
```

### Setup All Components
```bash
# Checkout all repos + patch springboot deployments
./localdev.py --setup
```

### Update Repositories
```bash
# Pull latest changes for all checked-out repos
./localdev.py --update
```

### Restore Deployments
```bash
# Restore springboot deployments to original state
./localdev.py --restore
```

## Key Differences

| Aspect | SpringBoot | Webapp |
|--------|-----------|---------|
| **Deployment patching** | ✅ Yes | ❌ No |
| **Image override** | ✅ JDK image | ❌ Keep nginx |
| **Command injection** | ✅ `java -jar` | ❌ Keep nginx CMD |
| **VolumeMount** | ✅ Auto-added | ⏭️  Via values.yaml |
| **Configuration** | 🔧 localdev.ini | 🔧 localdev.ini + values.yaml |
| **Build step** | `./gradlew build` | `npm run build` |
| **Restart method** | `kubectl delete pod` | `helm upgrade` |

## Troubleshooting

### Webapp not loading latest changes

1. **Check build output:**
   ```bash
   ls -la ~/ph-ee-operations-web/dist/web-app/
   ```

2. **Verify values.yaml path matches:**
   ```bash
   grep "ops-web-dist" config/ph_values.yaml
   ```

3. **Check pod is using hostPath:**
   ```bash
   kubectl describe pod -n paymenthub -l app=ph-ee-operations-web | grep -A 5 "Volumes:"
   ```

4. **Rebuild and upgrade:**
   ```bash
   cd ~/ph-ee-operations-web
   npm run build
   helm upgrade -n paymenthub phee ./repos/ph_template/helm/gazelle -f config/ph_values.yaml
   ```

### SpringBoot app not loading latest changes

1. **Check JAR was built:**
   ```bash
   ls -lh ~/ph-ee-connector-channel/build/libs/*.jar
   ```

2. **Verify deployment was patched:**
   ```bash
   kubectl describe pod -n paymenthub -l app=ph-ee-connector-channel | grep -A 2 "Command:"
   ```

3. **Rebuild and restart:**
   ```bash
   cd ~/ph-ee-connector-channel
   ./gradlew clean build -x test
   kubectl delete pod -n paymenthub -l app=ph-ee-connector-channel
   ```

## Summary

- **SpringBoot apps**: Use `localdev.py --setup` to patch deployments automatically
- **Webapp apps**: Use `localdev.py --checkout` for repos, configure via `values.yaml`
- Both approaches enable rapid local development without rebuilding Docker images
- SpringBoot = JAR execution, Webapp = static file serving
