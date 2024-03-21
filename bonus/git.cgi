#!/usr/bin/env -S qjs --std
/* adds clickable links to commit hashes
 * usage:
 * 0. install QuickJS (https://bellard.org/quickjs)
 * 1. put this script in your CGI directory
 * 2. chmod +x /your/cgi-bin/directory/git.cgi
 * 3. ln -s /your/cgi-bin/directory/git.cgi /usr/local/bin/gitcha
 * 4. gitcha log
 * other params work too, but for those it's more convenient to use git.
 * (if you have ansi2html, it also works with w3m. just set GITCHA_CHA=w3m) */

const gitcha = std.getenv("GITCHA_GITCHA") ?? "gitcha";
if (scriptArgs[0].split('/').at(-1) == gitcha) {
	const cha = std.getenv("GITCHA_CHA") ?? 'cha';
	const params = encodeURIComponent(scriptArgs.slice(1)
		.map(x => encodeURIComponent(x)).join(' '));
	const [path, _] = os.getcwd();
	const prefix = cha == "w3m" ? '/cgi-bin/' : "cgi-bin:";
	os.exec([cha, `${prefix}git.cgi?params=${params}&path=${path}&prefix=${prefix}`]);
	std.exit(0);
}

const query = {};
for (const p of std.getenv("QUERY_STRING").split('&')) {
	const sp = p.split('=');
	query[decodeURIComponent(sp[0])] = decodeURIComponent(sp[1] ?? '');
}

os.chdir(query.path);

const config = ["-c", "color.ui=always", "-c", "log.decorate=short"];
const params = query.params ? decodeURIComponent(query.params).split(' ')
	.map(x => decodeURIComponent(x)) : [];

if (params[0] == "log") {
	std.out.puts('Content-Type: text/html\n\n');
	const [read_fd, write_fd] = os.pipe();
	const [read_fd2, write_fd2] = os.pipe();
	os.exec(["git", ...config, ...params], {
		stdout: write_fd,
		block: false
	});
	os.close(write_fd);
	const libexecDir = std.getenv("CHA_LIBEXEC_DIR") ??
		'/usr/local/libexec/chawan';
	os.exec([libexecDir + "/ansi2html"], {
		stdin: read_fd,
		stdout: write_fd2,
		block: false
	});
	os.close(read_fd);
	os.close(write_fd2);
	const f = std.fdopen(read_fd2, "r");
	const cgi = `${query.prefix}git.cgi?prefix=${query.prefix}&path=${query.path}&params=show`;
	const titleParams = params.join(' ').replace(/[&<>]/g,
		x => ({'&': '&amp', '<': '&lt', '>': '&gt'}[x]));
	console.log(`<!DOCTYPE html>\n<title>git ${titleParams}</title>`);
	while ((l = f.getline()) !== null) {
		console.log(l.replace(/[a-f0-9]{40}/g,
			x => `<a href='${cgi}%20${x}'>${x}</a>`));
	}
	f.close();
} else {
	std.out.puts('Content-Type: text/x-ansi\n\n');
	const pid = os.exec(["git", ...config, ...params], {block: false});
	waitpid(pid, 0);
}