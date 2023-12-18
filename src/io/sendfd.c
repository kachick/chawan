#include <sys/socket.h>
#include <string.h>

/* See https://stackoverflow.com/a/4491203
 * Send a file handle to socket `sock`.
 * Returns: 1 on success, -1 on error. I *think* this never returns * 0. */
ssize_t sendfd(int sock, int fd)
{
	struct msghdr hdr;
	struct iovec iov;
	int cmsgbuf[CMSG_SPACE(sizeof(int))];
	char buf = '\0';
	struct cmsghdr *cmsg;

	memset(&hdr, 0, sizeof(hdr));
	iov.iov_base = &buf;
	iov.iov_len = 1;
	hdr.msg_iov = &iov;
	hdr.msg_iovlen = 1;
	hdr.msg_control = &cmsgbuf[0];
	hdr.msg_controllen = CMSG_LEN(sizeof(fd));
	cmsg = CMSG_FIRSTHDR(&hdr);
	cmsg->cmsg_len = CMSG_LEN(sizeof(fd));
	cmsg->cmsg_level = SOL_SOCKET;
	cmsg->cmsg_type = SCM_RIGHTS;
	*((int *)CMSG_DATA(cmsg)) = fd;
	return sendmsg(sock, &hdr, 0);
}
