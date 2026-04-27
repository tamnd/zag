import contextlib
import io

# contextmanager decorator
@contextlib.contextmanager
def managed(val):
    print('enter', val)
    yield val * 2
    print('exit', val)

with managed(5) as result:
    print('inside', result)                            # inside 10

# suppress
with contextlib.suppress(ValueError):
    raise ValueError("suppressed")
print('after suppress')                                # after suppress

with contextlib.suppress(TypeError, ValueError):
    int('not a number')
print('after suppress2')                               # after suppress2

# redirect_stdout
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    print('captured')
print(buf.getvalue().strip())                          # captured

# closing
class Resource:
    def close(self):
        print('closed')

with contextlib.closing(Resource()) as r:
    print('using resource')                            # using resource
# closed

# nullcontext
with contextlib.nullcontext(42) as val:
    print(val)                                         # 42

print('done')
