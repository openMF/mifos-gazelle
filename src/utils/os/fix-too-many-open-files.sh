#!/usr/bin/env bash
# this script increases the defaul number of file descriptors at the OS level
# and will restart the k3s server 

#------------------------------------------------------------
# Description : configures the number of file descriptors and prevents of fixes 
#               the EMFILE errors that can happen in pods
#               especially in low resource deployments 
# Usage : configure_kernel_params
#------------------------------------------------------------
configure_kernel_params() {
    echo "Checking current kernel parameters for K3s..."
    
    # Define target values
    local target_max_watches=524288
    local target_max_instances=1024
    local target_file_max=2097152
    
    # Get current values
    local current_watches=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)
    local current_instances=$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)
    local current_file_max=$(sysctl -n fs.file-max 2>/dev/null || echo 0)
    
    # Check if values already match targets
    local needs_update=false
    
    if [ "$current_watches" -ne "$target_max_watches" ]; then
        echo "  fs.inotify.max_user_watches: $current_watches -> $target_max_watches"
        needs_update=true
    else
        echo "  fs.inotify.max_user_watches: $current_watches (already set)"
    fi
    
    if [ "$current_instances" -ne "$target_max_instances" ]; then
        echo "  fs.inotify.max_user_instances: $current_instances -> $target_max_instances"
        needs_update=true
    else
        echo "  fs.inotify.max_user_instances: $current_instances (already set)"
    fi
    
    if [ "$current_file_max" -ne "$target_file_max" ]; then
        echo "  fs.file-max: $current_file_max -> $target_file_max"
        needs_update=true
    else
        echo "  fs.file-max: $current_file_max (already set)"
    fi
    
    # Apply settings if needed
    if [ "$needs_update" = true ]; then
        echo ""
        echo "Applying kernel parameter configuration..."
        
        sudo tee /etc/sysctl.d/99-k3s.conf <<EOF
fs.inotify.max_user_watches = $target_max_watches
fs.inotify.max_user_instances = $target_max_instances
fs.file-max = $target_file_max
EOF
        
        # Load the new settings immediately
        sudo sysctl --system
        
        echo ""
        echo "✓ Kernel parameters configured successfully!"
        echo ""
        echo "Verifying new values:"
        
        # Get and display new values for changed parameters
        if [ "$current_watches" -ne "$target_max_watches" ]; then
            local new_watches=$(sysctl -n fs.inotify.max_user_watches)
            echo "  fs.inotify.max_user_watches: $current_watches -> $new_watches"
        fi
        
        if [ "$current_instances" -ne "$target_max_instances" ]; then
            local new_instances=$(sysctl -n fs.inotify.max_user_instances)
            echo "  fs.inotify.max_user_instances: $current_instances -> $new_instances"
        fi
        
        if [ "$current_file_max" -ne "$target_file_max" ]; then
            local new_file_max=$(sysctl -n fs.file-max)
            echo "  fs.file-max: $current_file_max -> $new_file_max"
        fi
        
        echo ""
        echo "Restarting K3s to apply new limits..."
        
        # Restart K3s service to pick up new kernel parameters
        if systemctl is-active --quiet k3s; then
            sudo systemctl restart k3s
            echo "✓ K3s service restarted"
        elif systemctl is-active --quiet k3s-agent; then
            sudo systemctl restart k3s-agent
            echo "✓ K3s agent service restarted"
        else
            echo "⚠ K3s service not found or not running. Please restart K3s manually:"
            echo "  sudo systemctl restart k3s"
            echo "  or"
            echo "  sudo systemctl restart k3s-agent"
        fi
    else
        echo ""
        echo "✓ All kernel parameters already set correctly. No changes needed."
    fi
}

# Run the function
configure_kernel_params