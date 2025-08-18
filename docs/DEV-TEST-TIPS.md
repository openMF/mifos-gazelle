# Enabling Local Code Mounting for Kubernetes Development and Debugging

This document provides a guide on how to modify your existing Kubernetes Deployment YAML files to enable mounting your local filesystem into a container using `hostPath` volumes. This setup is allows  you to modify on the code locally and see the changes reflected in your running Mifos Gazelle Kubernetes environment without the need for Docker image rebuilds.

**Important Security Note:** Using `hostPath` volumes grants your containers direct access to the host's filesystem. This poses significant security risks and is **strongly discouraged for production environments**. This method which is inline with current Mifos Gazelle versions being for demonstration and test should be used solely for local development and debugging purposes.

## Understanding the Approach

The core idea is to instruct Kubernetes to mount a directory from your local machine directly into a specific path within your container. This allows the application running inside the container to access and execute the code present in your local project directory.

## Modifying Your `Deployment.yaml`

Follow these steps to adapt your existing `Deployment.yaml` file:

1. **Identify the Target Deployment:**
   Locate the `Deployment.yaml` file for the specific application you wish to debug locally. For example mifos-gazelle/repos/ph_template/helm/ph-ee-engine/connector-bulk/templates

2. **`Edit the spec.template.spec.containers Section:`**
   Within the `spec.template.spec.containers` array (usually containing a single container definition), make the following modifications:

   * **`Change the image:`** Replace the original Docker image specified in the `image` field with a generic base image that provides the necessary runtime environment for your application (e.g., `openjdk:17` for Java). The application code will now be sourced from the mounted local volume.

     ```
     spec:
       template:
         spec:
           containers:
           - name: your-container-name
             image: openjdk:17 # Example for a Java application
             # ... other container configurations ...
     
     ```

   * **`Add volumeMounts:`** Introduce a `volumeMounts` section to define where the local volume will be mounted inside the container.

     ```
             volumeMounts:
             - name: local-code
               mountPath: /app # Choose a suitable mount path within the container
     
     ```

     * `name`: This name (`local-code` in the example) will be used to reference the volume defined in the `spec.template.spec.volumes` section.

     * `mountPath`: This is the absolute path within the container where your local project files will be accessible. `/app` is a common and recommended choice.

   * **``Modify the command (and potentially args):``** Adjust the `command` (and potentially the `args`) of your container to execute your application from the mounted directory. You'll need to specify the correct path to your application's executable relative to the `mountPath`.

     For a Spring Boot application packaged as a JAR file, the modification might look like this:

     ```
             command: ["java", "-jar", "/app/build/libs/your-application-name.jar"]
     
     ```

     Ensure you replace `/app/build/libs/your-application-name.jar` with the actual path to your built JAR file within the mounted directory structure. The path will be relative to the `mountPath` you defined earlier.

3. **`Add the spec.template.spec.volumes Section:`**
   At the same level as the `containers` section within `spec.template.spec`, add a `volumes` section to define the `hostPath` volume.

   ````yaml
   spec:
     template:
       spec:
         containers:
         # ... container definition ...
         volumes:
         - name: local-code # Must match the name in volumeMounts
           hostPath:
             path: /path/to/your/local/project/directory # Replace with your local project path
             type: Directory # Specify the type of the host path
name: This must match the name you used in the volumeMounts section of your container (e.g., local-code).hostPath: Defines the source on the host machine.path: Crucially, replace /path/to/your/local/project/directory with the absolute path to your local project directory on your development machine. This is the root directory of your codebase.type: Specifies the type of the hostPath volume. For mounting your project code, Directory is the most common and appropriate type, assuming your local project is a directory. Other types include File, DirectoryOrCreate, FileOrCreate, Socket, CharDevice, and BlockDevice.
## Example Modification (General Structure)

Here's a conceptual example illustrating the key changes:

```
apiVersion: apps/v1
kind: Deployment
metadata:
name: your-app-dev
spec:
replicas: 1
selector:
 matchLabels:
   app: your-app-dev
template:
 metadata:
   labels:
     app: your-app-dev
 spec:
   containers:
   - name: your-app-container
     image: your-base-runtime-image:latest # Replace with a base image (e.g., openjdk:17, python:3.9-slim)
     # ... other container configurations (ports, env vars, etc.) ...
     command: ["your-application-entrypoint", "/app/your/application/main"] # Adjust command
     volumeMounts:
     - name: local-code
       mountPath: /app
   volumes:
   - name: local-code
     hostPath:
       path: /Users/yourusername/dev/your-project # Replace with your local path
       type: Directory

```

**```Remember to adapt the image, command, and path to match your specific application and project structure.```**

## Applying the Modified Deployment

1. **Save the changes** to your `Deployment.yaml` file. It's often a good practice to create a separate file (e.g., `deployment-dev.yaml`) for your development configurations to avoid conflicts with production deployments.

2. **Apply the modified deployment to your Kubernetes cluster:**

```
kubectl apply -f deployment-dev.yaml

```

3. **Verify the Pod:** Ensure that the pod starts correctly and that the local volume is successfully mounted inside the container. You can use the following `kubectl` commands:

* `kubectl describe pod <pod-name>`: Inspect the pod details, including the mounted volumes.

* `kubectl exec -it <pod-name> -- ls /app`: List the contents of the `/app` directory (or your chosen `mountPath`) within the running container to verify that your local files are present.

## Development Workflow

With this setup, your development workflow will involve:

1. Ensuring your Kubernetes cluster is running.

2. Applying the modified deployment YAML.

3. Making changes to your application code on your local filesystem using your preferred IDE.

4. Depending on your application's capabilities (e.g., hot reloading features like Spring Boot DevTools), changes might be reflected automatically or require a manual restart of the application within the container.

5. You can then debug your application running within the Kubernetes environment using your IDE's remote debugging features. You might need to configure specific JVM arguments or similar settings in your container's `command` to enable remote debugging and then set up port forwarding to connect your local debugger.

## Reverting to Production Configuration

When you are finished with local development and want to deploy using your fully built Docker image, remember to:

* Revert the changes made to your `Deployment.yaml` file, particularly the `image`, `command`, `volumeMounts`, and `volumes` sections.

* Apply the original or production-ready `Deployment.yaml` file to your cluster.

By following these steps, you can effectively leverage `hostPath` volumes for a more streamlined local development and debugging experience with your Kubernetes applications. However, always be mindful of the security implications and ensure this approach is strictly limited to your development environment.
```
