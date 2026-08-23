# Refactoring Plan: Shell Script Standardization (Google Style Guide)

## Goal
To refactor the `run.sh` and its downstream scripts (e.g., `commandline.sh`, `logger.sh`, `helpers.sh`) to align with the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html), improving maintainability, reliability, and predictability.

## 1. Core Standardizations (Global)

### **Strict Mode Implementation**
- Add `set -euo pipefail` to the top of all entry-point and primary scripts.
- **Why:** To ensure the script fails immediately on errors, unset variables, or pipeline failures, preventing "silent failures."

### **Naming Conventions**
- **Constants (Global):** Use `UPPER_S**_CASE` (e.g., `KUBECTL_VERSION`).
- **Global Variables:** Use `UPPER_S_CASE` (e.g., `RUN_DIR`, `APPS_DIR`).
- **Local Variables:** Use `lowercase_snake_case` (e.g., `config_path`, `app_name`).
- **Functions:** Use `lowercase_snake_case`.

### **Standardized Error Handling**
- Implement a unified logging/error reporting pattern across all scripts.
- Ensure all error messages are redirected to `stderr` (`>&2`).

---

  ## 2. `run.sh` Refactor

### **Bootstrap Improvement**
- Simplify the macOS Bash 4+ re-execution logic.
- Replace brittle `cd ... && pwd` with modern, safer path resolution.

### **Environment Sanitization**
- Standardize `PATH` manipulation to ensure predictable behavior on both macOS (Homebrew) and Linux.

---

## 3. `src/commandline/commandline.sh` Refactor

### **Variable Scoping (Crucial)**
- **Audit `load_config_from_file`**: Convert all `config_...` variables from global scope to `local` scope.
- **Audit `get_options`**: Ensure all parsing variables are `local`.
- **Why:** To prevent "variable leakage" where a function accidentally modifies the global state of the deployment process.

### **Function Documentation**
- Standardize all function headers to include:
    - **Description**: What the function does.
    - **Arguments**: `$1`, `$2`, etc., with descriptions.
    - **Returns/Outputs**: Success/failure indicators.

### **Logic & safety**
- **Eliminate `eval`**: Replace `eval "export $var_name=\"\$value\""` with safer assignment methods (e.g., `printf -v` or direct assignment) to prevent injection risks.
- **Argument Parsing**: Refactor `get_options` to use a more robust, standardized `getopts` pattern.

---

## 4. Verification & Quality Assurance

### **Linting**
- Run `shellcheck` on every modified file to validate adherence to the style guide and catch syntax errors.

### **Functional Testing**
- **Regression Test 1**: Execute `deploy` mode to ensure `PATH` and `PYTHON3` lookups remain functional.
- **Regression Test 2**: Execute `cleanall` mode to ensure the logic for resource deletion is not disrupted by variable scoping changes.
- **Regression Test 3**: Verify `pipx`/`crudini` installation logic on macOS.

## 5. Implementation Strategy
1.  **Phase 1**: Apply `set -e` and `local` variable scoping (Highest impact on stability).
2.  **Phase 2**: Standardize Naming and Documentation.
3.  **Phase 3**: Refactor `eval` and complex logic.
4.  **Phase 4**: Final `shellcheck` and functional validation.
