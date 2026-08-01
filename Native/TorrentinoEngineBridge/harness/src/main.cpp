// Torrentino engine harness — process entry point (WP-01).
//
// Role: nothing but a call through the C ABI boundary. Keeping main() this thin
//       is what proves the boundary is usable from non-C++ callers (Swift, ObjC)
//       exactly as WP-04 will need it.
#include "torrentino/harness/harness_api.h"

int main(int argc, char* argv[])
{
	return torrentino_harness_main(argc, argv);
}
