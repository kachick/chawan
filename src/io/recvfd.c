#include <sys/socket.h>
#include <string.h>

/* See https://stackoverflow.com/a/4491203
 * Receive a file handle from socket `sock`.
 * Sets `fd` to the result if recvmsg returns sizeof(int), otherwise to -1.
 * Returns: the return value of recvmsg; this may be -1. */
ssize_t recvfd(int sock, int *fd)
{
	ssize_t n;
	struct iovec iov;
	struct msghdr hdr;
	int cmsgbuf[CMSG_SPACE(sizeof(int))];
	struct cmsghdr *cmsg;
	char buf = '\0';

	iov.iov_base = &buf;
	iov.iov_len = 1;
	memset(&hdr, 0, sizeof(hdr));
	hdr.msg_iov = &iov;
	hdr.msg_iovlen = 1;
	hdr.msg_control = &cmsgbuf[0];
	hdr.msg_controllen = CMSG_SPACE(sizeof(int));
	n = recvmsg(sock, &hdr, 0);
	if (n <= 0) {
		*fd = -1;
		return n;
	}
	cmsg = CMSG_FIRSTHDR(&hdr);
	*fd = *((int *)CMSG_DATA(cmsg));
	return n;
}
