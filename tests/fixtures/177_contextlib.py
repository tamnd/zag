from contextlib import contextmanager, suppress, nullcontext, closing, ExitStack

# contextmanager decorator
@contextmanager
def managed(x):
    print('enter', x)
    yield x * 2
    print('exit', x)

with managed(3) as val:
    print('inside', val)

# suppress swallows exceptions
with suppress(ValueError):
    raise ValueError('ignored')
print('after suppress')

# nullcontext passes through its value
with nullcontext('hello') as val:
    print('nullcontext', val)

# ExitStack with suppress inside
with ExitStack() as stack:
    stack.enter_context(suppress(ValueError))
    raise ValueError('should be suppressed')
print('after ExitStack')
