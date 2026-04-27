import traceback
import io

# format_exc outside an exception context returns 'None\n'
result = traceback.format_exc()
print(result.strip())                                  # None

# capture a real exception
try:
    1 / 0
except ZeroDivisionError:
    text = traceback.format_exc()
    print('ZeroDivisionError' in text)                 # True
    print('Traceback' in text)                         # True

# print_exc to a StringIO buffer
buf = io.StringIO()
try:
    int('bad')
except ValueError:
    traceback.print_exc(file=buf)
out = buf.getvalue()
print('ValueError' in out)                             # True
print('invalid literal' in out)                        # True

# TracebackException
try:
    raise RuntimeError('boom')
except RuntimeError as e:
    te = traceback.TracebackException.from_exception(e)
    print(te.exc_type_str)                             # RuntimeError
    lines = ''.join(te.format())
    print('boom' in lines)                             # True

# format_tb
try:
    raise KeyError('k')
except KeyError:
    tb = traceback.extract_tb(traceback.sys.exc_info()[2])
    print(len(tb) > 0)                                 # True

print('done')
