/* This file is dedicated to the public domain.
 *
 * Gemini protocol adapter for Chawan.
 * Intended to be used through local CGI (by redirection in scheme-map).
 *
 * Usage: gmifetch
 *
 * Environment variables:
 * - MAPPED_URI_SCHEME, MAPPED_URI_HOST, MAPPED_URI_PORT, MAPPED_URI_PATH,
 *   MAPPED_URI_QUERY for the URL parts. (Parameters are ignored, gmifetch does
 *   not parse URLs.)
 * - GMIFETCH_KNOWN_HOSTS is used for setting the known_hosts file. If not set,
 *   we use $XDG_CONFIG_HOME/gmifetch/known_hosts, where $XDG_CONFIG_HOME falls
 *   back to $HOME/.config/gmifetch if not set. (TODO: add a way to set this
 *   in config.toml)
 */

#include <ctype.h>
#include <errno.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <pwd.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static SSL_CTX* ssl_ctx;
static SSL *ssl;
static BIO *conn;

/* CGI responses */
#define INPUT_RESPONSE "Content-Type: text/html\r\n" \
	"\r\n" \
	"<!DOCTYPE html>" \
	"<title>Input required</title>" \
	"<base href='%s'>" \
	"<h1>Input required</h1>" \
	"<p>" \
	"%s" \
	"<p>" \
	"<form method=POST><input type='%s' name='input'></form>"

#define SUCCESS_RESPONSE "Content-Type: %s\r\n" \
	"\r\n"

#define REDIRECT_RESPONSE "Status: 30%c\r\n" \
	"Location: %s\r\n" \
	"\r\n"

#define TEMPFAIL_RESPONSE "Content-Type: text/html\r\n" \
	"\r\n" \
	"<!DOCTYPE html>" \
	"<title>Temporary failure</title>" \
	"<h1>%s</h1>" \
	"<p>" \
	"%s"

#define PERMFAIL_RESPONSE "Content-Type: text/html\r\n" \
	"\r\n" \
	"<!DOCTYPE html>" \
	"<title>Permanent failure</title>" \
	"<h1>%s</h1>" \
	"<p>" \
	"%s"

#define CERTFAIL_RESPONSE "Content-Type: text/html\r\n" \
	"\r\n" \
	"<!DOCTYPE html>" \
	"<title>Certificate failure</title>" \
	"<h1>%s</h1>" \
	"<p>" \
	"%s"

#define INVALID_CERT_RESPONSE "Content-Type: text/html\r\n" \
	"\r\n" \
	"<!DOCTYPE html>\n" \
	"<title>Invalid certificate</title>\n" \
	"<h1>Invalid certificate</h1>\n" \
	"<p>\n" \
	"The certificate received from the server does not match the\n" \
	"stored certificate (expected %s, but got %s). Somebody may be\n" \
	"tampering with your connection.\n" \
	"<p>\n" \
	"If you are sure that this is not a man-in-the-middle attack,\n" \
	"please remove this host from %s.\n"

#define UNKNOWN_CERT_RESPONSE "Content-Type: text/html\r\n" \
	"\r\n" \
	"<!DOCTYPE html>" \
	"<title>Unknown certificate</title>" \
	"<h1>Unknown certificate</h1>" \
	"<p>\n" \
	"The hostname of the server you are visiting could not be found\n" \
	"in your list of known hosts (%s).\n" \
	"<p>\n" \
	"The server has sent us a certificate with the following\n" \
	"fingerprint:\n" \
	"<pre>%s</pre>\n" \
	"<p>Trust it?\n" \
	"<form method=POST>" \
	"<input type=submit name=trust_cert value=always>\n" \
	"<input type=submit name=trust_cert value=once>" \
	"<input type=hidden name=entry value='%s sha256 %s %lu'>" \
	"</form>"

#define UPDATED_CERT_RESPONSE "Content-Type: text/html\r\n" \
	"\r\n" \
	"<!DOCTYPE html>\n" \
	"<title>Certificate date changed</title>\n" \
	"<h1>Certificate date changed</h1>\n" \
	"<p>\n" \
	"The received certificate's date did not match the date in your\n" \
	"list of known hosts (%s).\n" \
	"<p>\n" \
	"The new expiration date is: %s.\n" \
	"<p>\n" \
	"Update it?\n" \
	"<form method=POST>" \
	"<input type=submit name=trust_cert value=always>" \
	"<input type=submit name=trust_cert value=once>\n" \
	"<input type=hidden name=entry value='%s sha256 %s %lu'>" \
	"</form>\n"

#define PDIE(x) \
	do { \
		fputs("Cha-Control: ConnectionError 1 " x ": ", stdout); \
		puts(strerror(errno)); \
		exit(1); \
	} while (0)

#define SDIE(x) \
	do { \
		fputs("Cha-Control: ConnectionError 5 " x ": ", stdout); \
		ERR_print_errors_fp(stdout); \
		exit(1); \
	} while (0)

#define DIE(x) \
	do { \
		puts("Cha-Control: ConnectionError 1 " x); \
		exit(1); \
	} while (0)

#define BUFSIZE 1024
#define PUBKEY_BUF_SIZE 8192

int check_cert(const char *theirs, const char *hostp, char **stored_digestp,
	char *linebuf, time_t their_time, FILE *known_hosts)
{
	char *p, *q, *hashp, *timep;
	int found;
	time_t our_time;

	rewind(known_hosts);
	found = 0;
	while (!found && fgets(linebuf, BUFSIZE, known_hosts)) {
		p = strstr(linebuf, " ");
		if (!p)
			DIE("Incorrectly formatted known_hosts file");
		*p = '\0';
		found = !strcmp(linebuf, hostp);
	}
	if (!found)
		return -1;
	hashp = p + 1;
	if (!(q = strstr(hashp, " ")))
		DIE("Incorrectly formatted known_hosts file");
	*q = '\0';
	if (strcmp(hashp, "sha256") && strcmp(hashp, "SHA256"))
		DIE("Unsupported digest format");
	*stored_digestp = q + 1;
	if (!(q = strstr(*stored_digestp, " "))) {
		timep = NULL;
		if ((q = strstr(*stored_digestp, "\n")))
			*q = '\0';
	} else {
		timep = q + 1;
		*q = '\0';
	}
	if (strcmp(theirs, *stored_digestp))
		return 0;
	if (!timep)
		return -2;
	our_time = (time_t)atol(timep);
	if (their_time != our_time)
		return -2;
	return 1;
}

static char HexTable[] = "0123456789ABCDEF";

void hex_encode(const unsigned char *inp, char *outbuf, int len)
{
	const unsigned char *p;
	char *q;

	for (p = inp, q = outbuf; p < &inp[len]; ++p) {
		if (p != inp)
			*q++ = ':';
		*q++ = HexTable[(*p >> 4) & 0xF];
		*q++ = HexTable[*p & 0xF];
	}
	*q++ = '\0';
}

static void hash_buf(const unsigned char *ibuf, int len, char *obuf2)
{
	unsigned int len2;
	EVP_MD_CTX* mdctx;
	unsigned char hashbuf[EVP_MAX_MD_SIZE];

	if (!(mdctx = EVP_MD_CTX_new()))
		SDIE("Failed to initialize MD_CTX");
	if (!EVP_DigestInit_ex(mdctx, EVP_sha256(), NULL))
		SDIE("Failed to initialize sha256");
	if (!EVP_DigestUpdate(mdctx, ibuf, len))
		SDIE("Failed to update digest");
	len2 = 0;
	if (!EVP_DigestFinal_ex(mdctx, hashbuf, &len2))
		SDIE("Failed to finalize digest");
	EVP_MD_CTX_free(mdctx);
	hex_encode(hashbuf, obuf2, len2);
}

/* 1: cert found & valid
 * 0: cert found & invalid
 * -1: cert not found
 * -2: cert found, but notAfter updated
 */
static int connect(const char *hostname, const char *hostp,
	char *linebuf, char **stored_digestp, time_t *their_time,
	char *hashbuf2, FILE *known_hosts)
{
	X509 *cert;
	const EVP_PKEY *pkey;
	unsigned char pubkey_buf[PUBKEY_BUF_SIZE + 1], *r;
	int len, res;
	const ASN1_TIME *notAfter;
	struct tm their_tm;

	if (!BIO_set_conn_hostname(conn, hostname)) /* includes port */
		SDIE("Error setting BIO hostname");
	BIO_get_ssl(conn, &ssl);
#define PREFERRED_CIPHERS "HIGH:!aNULL:!kRSA:!PSK:!SRP:!MD5:!RC4"
	if (!SSL_set_cipher_list(ssl, PREFERRED_CIPHERS))
		SDIE("Error failed to set cipher list");
	if (!SSL_set_tlsext_host_name(ssl, hostp))
		SDIE("Error failed to set tlsext host name");
	if (BIO_do_connect(conn) <= 0)
		SDIE("Failed to connect");
	if (!BIO_do_handshake(conn))
		SDIE("Failed handshake");
	if (!(cert = SSL_get_peer_certificate(ssl)))
		DIE("Failed to get certificate");
	if (!(pkey = X509_get0_pubkey(cert)))
		SDIE("Failed to decode public key");
	len = i2d_PUBKEY(pkey, NULL);
	if (len * 3 > PUBKEY_BUF_SIZE)
		DIE("Public key too long");
	r = pubkey_buf;
	if (i2d_PUBKEY(pkey, &r) != len)
		DIE("wat");
	hash_buf(pubkey_buf, len, hashbuf2);
	notAfter = X509_get0_notAfter(cert);
	if (!ASN1_TIME_to_tm(notAfter, &their_tm))
		DIE("Failed to parse time");
	if (X509_cmp_current_time(X509_get0_notBefore(cert)) >= 0)
		DIE("Wrong time");
	if (X509_cmp_current_time(notAfter) <= 0)
		DIE("Wrong time");
	*their_time = mktime(&their_tm);
	res = check_cert(hashbuf2, hostp, stored_digestp, linebuf, *their_time,
		known_hosts);
	X509_free(cert);
	return res;
}

static void read_response(const char *urlbuf)
{
	int bytes, total;
	const char *tmp;
	char *q, status0, status1;
	char buffer[BUFSIZE + 1];

	/* Read response */
	total = 0;
	/* Status code */
	while (((bytes = BIO_read(conn, buffer, 3 - total)) > 0 ||
			BIO_should_retry(conn)) && total < 3)
		total += bytes;
	if (total < 3 || !isdigit(status0 = buffer[0]) ||
			!isdigit(status1 = buffer[1]) || buffer[2] != ' ')
		DIE("Invalid status code");
	/* Meta */
	#define METALEN (total - 3)
	while (((bytes = BIO_read(conn, &buffer[METALEN], 1024 - METALEN)) > 0 ||
			BIO_should_retry(conn)) && METALEN < BUFSIZE)
		total += bytes;
	q = strstr(buffer, "\r\n");
	if (!q)
		DIE("Invalid status line");
	*q = '\0';
	/* buffer is now META. */
	switch (status0) {
	case '1': /* input */
		/* META is the prompt. */
		printf(INPUT_RESPONSE, urlbuf, buffer, status1 == '1' ?
			"password" /* sensitive input */ :
			"search" /* input */);
		break;
	case '2': /* success */
		/* META is the content type. */
		printf(SUCCESS_RESPONSE, *buffer ?
			buffer :
			"text/gemini; charset=utf-8" /* fallback */);
		/* Body */
		/* flush any data remaining in buffer */
		total -= 5 + (q - buffer); /* code + space + meta + \r\n len */
		if (total > 0)
			fwrite(&q[2], 1, total, stdout);
		while ((bytes = BIO_read(conn, buffer, BUFSIZE)) > 0 ||
				BIO_should_retry(conn))
			fwrite(buffer, 1, bytes, stdout);
		break;
	case '3': /* redirect */
		/* META is the redirection URL. */
		printf(REDIRECT_RESPONSE, status1 == '0' ?
			'7' /* temporary */ :
			'1' /* permanent */, buffer);
		break;
	case '4': /* temporary failure */
		/* META is additional information. */
		/* TODO maybe set status code too? */
		switch (status1) {
		case '1':
			tmp = "Server unavailable";
			break;
		case '2':
			tmp = "CGI error";
			break;
		case '3':
			tmp = "Proxy error";
			break;
		case '4':
			tmp = "Slow down!";
			break;
		case '0':
		default: /* no additional information provided in the code */
			tmp = "Temporary failure";
			break;
		}
		printf(TEMPFAIL_RESPONSE, tmp, buffer);
		break;
	case '5': /* permanent failure */
		/* TODO maybe set status code too? */
		switch (status1) {
		case '1':
			tmp = "Not found";
			break;
		case '2':
			tmp = "Gone";
			break;
		case '3':
			tmp = "Proxy request refused";
			break;
		case '9':
			tmp = "Bad request";
			break;
		case '0':
		default: /* no additional information provided in the code */
			tmp = "Permanent failure";
			break;
		}
		printf(PERMFAIL_RESPONSE, tmp, buffer);
		break;
	case '6': /* permanent failure */
		/* TODO maybe set status code too? */
		switch (status1) {
		case '1':
			tmp = "Certificate not authorized";
			break;
		case '2':
			tmp = "Certificate not valid";
			break;
		case '0':
		default: /* no additional information provided in the code */
			tmp = "Certificate failure";
			break;
		}
		printf(CERTFAIL_RESPONSE, tmp, buffer);
	}
}

void decode_query(const char *input_url, char *output_buffer)
{
	const char *p;
	char *q, *endp, c;

	endp = &output_buffer[BUFSIZE];
	for (p = input_url, q = output_buffer; *p && q < endp; ++p, ++q) {
		if (*p != '%') {
			*q = *p;
		} else {
			if (!isxdigit(p[1] & 0xFF) || !isxdigit(p[2] & 0xFF))
				DIE("Invalid percent encoding");
			c = tolower(p[1] & 0xFF);
			*q = ('a' <= c && c <= 'z') ?
				c - 'a' + 10 :
				c - '0';
			c = tolower(p[2] & 0xFF);
			*q = (*q << 4) | (('a' <= c || c <= 'z') ?
				c - 'a' + 10 :
				c - '0');
			p += 2;
		}
	}
	if (q >= endp)
		DIE("Query too long");
	*q = '\0';
}


void read_post(const char *hostp, char *reqbuf, char *khsbuf,
	FILE **known_hosts)
{
	size_t n;
	char *p, *q;
	FILE *known_hosts_tmp;
	long last_pos, len, total;
	size_t khslen;
	char inbuf[BUFSIZE + 1], buffer[BUFSIZE + 1];

	n = fread(inbuf, 1, BUFSIZE, stdin);
	inbuf[n] = '\0';
	if ((p = strstr(inbuf, "input="))) {
		p += strlen("input=");
		decode_query(p, buffer);
		if (!(q = strstr(reqbuf, "?"))) { /* no query string */
			q = &reqbuf[strlen(reqbuf)];
			if (q == &reqbuf[BUFSIZE])
				DIE("Query too long");
			*q++ = '?';
		}
		for (; *p && q < &reqbuf[BUFSIZE]; ++p, ++q)
			*q = *p;
		if (q >= &reqbuf[BUFSIZE])
			DIE("Query too long");
		return;
	} else if (!(p = strstr(inbuf, "trust_cert="))) {
		DIE("Invalid POST request: trust_cert missing");
	}
	p += sizeof("trust_cert=") - 1;
	if (!strncmp(p, "always", 6)) {
		/* move to file end */
		fseek(*known_hosts, 0L, SEEK_END);
		last_pos = ftell(*known_hosts);
		if (!(p = strstr(p, "entry=")))
			DIE("Invalid POST request: missing entry");
		p += sizeof("entry=") - 1;
		decode_query(p, buffer);
		/* replace plus signs */
		p = buffer;
		while ((p = strstr(p, "+")))
			*p = ' ';
		fwrite(buffer, 1, strlen(buffer), *known_hosts);
		fwrite("\n", 1, 1, *known_hosts);
		khslen = strlen(khsbuf);
		khsbuf[khslen] = '~';
		khsbuf[khslen + 1] = '\0';
		if (!(known_hosts_tmp = fopen(khsbuf, "w+")))
			PDIE("Error opening temporary hosts file");
		rewind(*known_hosts);
		total = 0;
		while (fgets(buffer, BUFSIZE, *known_hosts)) {
			len = strlen(buffer);
			if (!len)
				continue;
			if ((total += len) > last_pos) {
				/* finished */
				fwrite(buffer, 1, len, known_hosts_tmp);
				break;
			}
			if (buffer[len - 1] != '\n') {
				/* clean up */
				fclose(known_hosts_tmp);
				unlink(khsbuf);
				DIE("Line too long");
			}
			if (!(p = strstr(buffer, " ")))
				DIE("Invalid entry in known_hosts file");
			*p = '\0';
			if (strcmp(buffer, hostp)) {
				*p = ' ';
				fwrite(buffer, 1, len, known_hosts_tmp);
			}
		}
		memcpy(buffer, khsbuf, BUFSIZE + 1);
		buffer[khslen] = '\0';
		fclose(*known_hosts);
		fclose(known_hosts_tmp);
		if (rename(khsbuf, buffer))
			PDIE("Failed to rename temporary file");
		khsbuf[khslen] = '\0';
		if (!(*known_hosts = fopen(khsbuf, "a+")))
			PDIE("Failed to re-open known hosts file");
	} else if (strncmp(p, "once", 4)) {
		DIE("Invalid POST request");
	}
}

FILE *open_known_hosts(char *khsbuf)
{
	const char *known_hosts_path, *xdg_dir, *home_dir;
	char *p;
	size_t len;
	struct stat s;
	FILE *known_hosts;

	known_hosts_path = getenv("GMIFETCH_KNOWN_HOSTS");
	if (!known_hosts_path) {
		xdg_dir = getenv("XDG_CONFIG_HOME");
		if ((xdg_dir = getenv("XDG_CONFIG_HOME"))) {
			len = strlen(xdg_dir);
#define CONFIG_REL "/gmifetch/known_hosts"
			if (len + sizeof(CONFIG_REL) > BUFSIZE)
				DIE("Error: config directory path too long");
			memcpy(khsbuf, xdg_dir, len);
			memcpy(&khsbuf[len], CONFIG_REL, sizeof(CONFIG_REL));
		} else {
			if (!(home_dir = getenv("HOME")))
				home_dir = getpwuid(getuid())->pw_dir;
			if (!home_dir)
				DIE("Error: failed to get HOME directory");
#undef CONFIG_REL
#define CONFIG_REL "/.config/gmifetch/known_hosts"
			len = strlen(home_dir);
			if (len + sizeof(CONFIG_REL) > BUFSIZE)
				DIE("Error: home directory path too long");
			memcpy(khsbuf, home_dir, len);
			memcpy(&khsbuf[len], CONFIG_REL, sizeof(CONFIG_REL));
		}
	} else {
		len = strlen(known_hosts_path);
		if (len > BUFSIZE)
			DIE("Error: known hosts path too long");
		memcpy(khsbuf, known_hosts_path, len);
	}
	p = khsbuf;
	if (*p == '/')
		++p;
	for (; *p; ++p) {
		if (*p == '/') {
			*p = '\0';
			if (stat(khsbuf, &s) == -1) {
				if (errno != ENOENT)
					PDIE("Error calling stat");
				if (mkdir(khsbuf, 0755) == -1)
					PDIE("Error calling mkdir");
			} else if (!S_ISDIR(s.st_mode)) {
				if (mkdir(khsbuf, 0755) == -1)
					PDIE("Error calling mkdir");
			}
			*p = '/';
		}
	}
	if (!(known_hosts = fopen(khsbuf, "a+")))
		PDIE("Error opening known hosts file");
	return known_hosts;
}

int main(void)
{
	const char *schemep = getenv("MAPPED_URI_SCHEME");
	const char *hostp = getenv("MAPPED_URI_HOST");
	const char *portp = getenv("MAPPED_URI_PORT");
	const char *pathp = getenv("MAPPED_URI_PATH");
	const char *queryp = getenv("MAPPED_URI_QUERY");
	const char *method = getenv("REQUEST_METHOD");
	const char *all_proxy = getenv("ALL_PROXY");
	char *stored_digestp;
	time_t their_time;
	char hashbuf2[EVP_MAX_MD_SIZE * 3 + 1];
	char hostname[BUFSIZE + 1], reqbuf[BUFSIZE + 1] = "gemini://",
		khsbuf[BUFSIZE + 2], linebuf[BUFSIZE + 1];
	FILE *known_hosts;

#define PROXY_ERR "gmifetch does not support proxies yet. Please disable" \
	"your proxy for gemini URLs if you wish to proceed anyway."
	if (all_proxy && *all_proxy)
		DIE(PROXY_ERR);
	known_hosts = open_known_hosts(khsbuf);
	/* setup SSL */
	OPENSSL_init_ssl(0, NULL);
	ssl_ctx = SSL_CTX_new(TLS_client_method());
	SSL_CTX_set_min_proto_version(ssl_ctx, TLS1_2_VERSION);
	/* check received URL */
	if (!(conn = BIO_new_ssl_connect(ssl_ctx)))
		SDIE("Error creating BIO");
	if (!schemep || !*schemep || strcmp(schemep, "gemini"))
		DIE("Invalid scheme");
	if (!hostp || !*hostp)
		DIE("Missing hostname");
	if (!portp || !*portp)
		portp = "1965";
	if (!pathp || !*pathp)
		pathp = "/";
	if (!queryp)
		queryp = "";
	/* Hostname for BIO_set_conn_hostname */
	strncpy(hostname, hostp, sizeof(hostname) - 1);
#define CAT(me, ow) strncat(me, ow, sizeof(me) - strlen(me) - 1);
	CAT(hostname, ":");
	CAT(hostname, portp);
	/* Note: we do not include the port number in the request string,
	 * otherwise some servers refuse to serve anything.
	 *
	 * (I really wish this was explicitly mentioned in the standard.
	 * Something like:
	 *
	 * WARNING: some gemini servers will not accept URLs containing the
	 * default port number!!!)
	 */
	CAT(reqbuf, hostp);
	CAT(reqbuf, pathp);
	if (*queryp) {
		CAT(reqbuf, "?");
		CAT(reqbuf, queryp);
	}
	/* read_post may modify reqbuf (it appends a query string for input form
	 * responses) */
	if (method && !strcmp(method, "POST"))
		read_post(hostp, reqbuf, khsbuf, &known_hosts);
	CAT(reqbuf, "\r\n");
	switch (connect(hostname, hostp, linebuf, &stored_digestp, &their_time,
		hashbuf2, known_hosts))
	{
	case 1: /* valid certificate, connect */
		BIO_puts(conn, reqbuf);
		read_response(reqbuf);
		break;
	case 0: /* invalid certificate */
		printf(INVALID_CERT_RESPONSE, stored_digestp, hashbuf2,
			khsbuf);
		break;
	case -1: /* no certificate */
		printf(UNKNOWN_CERT_RESPONSE, khsbuf, hashbuf2, hostp,
			hashbuf2, (unsigned long)their_time);
		break;
	case -2: /* -2: updated expiration date */
		printf(UPDATED_CERT_RESPONSE, khsbuf,
			ctime(&their_time), hostp, hashbuf2,
			(unsigned long)their_time);
		break;
	default: DIE("wat 2");
	}
	BIO_free_all(conn);
	exit(0);
}
