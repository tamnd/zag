import subprocess

# Basic run with capture and text mode
r = subprocess.run(["/bin/echo", "hello"], capture_output=True, text=True)
print(r.returncode)
print(r.stdout.strip())

# check_output returns stdout as bytes by default, text=True for str
out = subprocess.check_output(["/bin/echo", "world"], text=True)
print(out.strip())

# Non-zero return code
r2 = subprocess.run(["/bin/sh", "-c", "exit 2"], capture_output=True)
print(r2.returncode)

# check=True raises CalledProcessError
try:
    subprocess.run(["/bin/sh", "-c", "exit 1"], check=True)
except subprocess.CalledProcessError as e:
    print("CalledProcessError")
    print(e.returncode)

# Constants exist and are not None
print(subprocess.PIPE is not None)
print(subprocess.DEVNULL is not None)

# input kwarg pipes bytes to stdin
r3 = subprocess.run(["/bin/cat"], input=b"hello\n", capture_output=True)
print(r3.stdout)
print(r3.returncode)
