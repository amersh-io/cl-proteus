/* The main executable of an application bundle made by cl-proteus/bundle.
 *
 * An SBCL executable carries its core after the end of the Mach-O file,
 * where a code signature cannot cover it, so the bundle keeps the SBCL
 * runtime and the core apart: Contents/MacOS/sbcl and
 * Contents/Resources/app.core. This program starts the one with the other,
 * whatever SBCL_HOME says, and passes its own arguments on.
 */

#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
  char path[PATH_MAX], real[PATH_MAX], runtime[PATH_MAX], core[PATH_MAX];
  uint32_t size = sizeof path;
  if (_NSGetExecutablePath(path, &size) != 0 || realpath(path, real) == NULL) {
    perror("launcher: finding the executable");
    return 1;
  }
  const char *dir = dirname(real);
  snprintf(runtime, sizeof runtime, "%s/sbcl", dir);
  snprintf(core, sizeof core, "%s/../Resources/app.core", dir);

  const char *options[] = {"--core", core, "--noinform", "--disable-ldb",
                           "--lose-on-corruption", "--end-runtime-options"};
  const int count = sizeof options / sizeof options[0];
  char **args = calloc(argc + count + 1, sizeof *args);
  if (args == NULL) {
    perror("launcher");
    return 1;
  }
  int n = 0;
  args[n++] = runtime;
  for (int i = 0; i < count; i++) args[n++] = (char *)options[i];
  for (int i = 1; i < argc; i++) args[n++] = argv[i];

  unsetenv("SBCL_HOME");
  execv(runtime, args);
  perror("launcher: starting the Lisp runtime");
  return 1;
}
