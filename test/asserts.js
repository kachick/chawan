function assert(x, msg) {
	const mymsg = msg ? ": " + msg : "";
	if (!x)
		throw new TypeError("Assertion failed" + mymsg);
}

function assert_throws(expr, error) {
	try {
		eval(expr);
	} catch (e) {
		if (e instanceof Error)
			return;
	}
	throw new TypeError("Assertion failed");
}

function assert_equals(a, b) {
	assert(a === b, "Expected " + b + " but got " + a);
}

function assert_instanceof(a, b) {
	assert(a instanceof b, a + " not an instance of " + b);
}
