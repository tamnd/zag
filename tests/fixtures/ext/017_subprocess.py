import subprocess

# run() with capture_output
result = subprocess.run(['echo', 'hello'], capture_output=True, text=True)
print(type(result).__name__)                           # CompletedProcess
print(result.returncode)                               # 0
print(result.stdout.strip())                           # hello
print(result.stderr)                                   # (empty string)

# CompletedProcess attributes
print(hasattr(result, 'args'))                         # True
print(hasattr(result, 'returncode'))                   # True
print(hasattr(result, 'stdout'))                       # True
print(hasattr(result, 'stderr'))                       # True

# PIPE and DEVNULL constants
print(subprocess.PIPE == -1)                           # True
print(subprocess.DEVNULL == -3)                        # True
print(subprocess.STDOUT == -2)                         # True

# run() with PIPE explicitly
r2 = subprocess.run(['echo', 'world'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
print(r2.stdout.strip())                               # b'world'
print(r2.returncode)                                   # 0

# Non-zero exit code
r3 = subprocess.run(['false'], capture_output=True)
print(r3.returncode != 0)                              # True

# check_output
out = subprocess.check_output(['echo', 'hi'], text=True)
print(out.strip())                                     # hi

print('done')
