#include <stddef.h>
#include <sys/socket.h>
#include <sys/un.h>

int connect_unix_from_c(int socket, const char *path, int pathlen)
{
	struct sockaddr_un sa = {
		.sun_family = AF_UNIX
	};
	int len = offsetof(struct sockaddr_un, sun_path) + pathlen + 1;

	memcpy(sa.sun_path, path, pathlen + 1);
	return connect(socket, (struct sockaddr *)&sa, len);
}