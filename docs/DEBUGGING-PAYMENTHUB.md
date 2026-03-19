# Debugging Payment Hub Components in Gazelle

This guide provides step-by-step instructions for attaching a Java debugger (such as VS Code or IntelliJ IDEA) to Payment Hub EE components running inside a Gazelle Kubernetes deployment. 

Following this guide ensures you have full debugger functionality, including stack traces, breakpoints, and **variable evaluation**.

## The "Missing Variables" Issue
A common issue when debugging remote Java containers (Java 9+) is being able to connect and step through the stack trace, but failing to evaluate any variables. 

This occurs because the default JDWP agent often binds to `localhost` (e.g., `address=localhost:5010`). Inside a Kubernetes pod, this restricts the debugger to the container's internal loopback interface, breaking variable mapping over `kubectl port-forward`. 

**The Fix:** You must bind the address to all interfaces using `*` (e.g., `address=*:5005`).

---

## Prerequisites
1. A running Gazelle deployment with Payment Hub components.
2. `kubectl` configured and connected to your cluster.
3. A Java IDE with the target component's source code open locally.

---

## Step 1: Enable the Java Debug Agent via Helm

Payment Hub Helm charts support the `extraEnvs` configuration block (implemented in GAZ-62). To enable the debugger, pass the `JAVA_TOOL_OPTIONS` environment variable with the corrected address binding.

Add the following to your deployment overrides/values:

```yaml
    deployment:
      extraEnvs:
        - name: JAVA_TOOL_OPTIONS
          value: |
            -Xms128m
            -Xmx256m
            -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005