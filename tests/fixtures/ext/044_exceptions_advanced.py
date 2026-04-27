# Advanced exception handling

# Exception chaining
def cause_error():
    try:
        raise ValueError('original')
    except ValueError as e:
        raise RuntimeError('wrapped') from e

try:
    cause_error()
except RuntimeError as e:
    print(str(e))                                     # wrapped
    print(e.__cause__ is not None)                    # True

# Exception groups (Python 3.11+) - skip, use multi-except instead
# Multiple except clauses
def categorize(x):
    try:
        if x < 0:
            raise ValueError('negative')
        if x == 0:
            raise ZeroDivisionError('zero')
        return 100 // x
    except ZeroDivisionError:
        return -1
    except ValueError:
        return -2

print(categorize(5))                                  # 20
print(categorize(0))                                  # -1
print(categorize(-3))                                 # -2

# finally clause
def with_finally(x):
    result = []
    try:
        result.append('try')
        if x:
            raise ValueError('error')
        result.append('no error')
    except ValueError:
        result.append('except')
    finally:
        result.append('finally')
    return result

print(with_finally(False))                            # ['try', 'no error', 'finally']
print(with_finally(True))                             # ['try', 'except', 'finally']

# Custom exception hierarchy
class AppError(Exception):
    pass

class ValidationError(AppError):
    def __init__(self, field, msg):
        self.field = field
        self.msg = msg
        super().__init__(f'{field}: {msg}')

class NetworkError(AppError):
    pass

try:
    raise ValidationError('email', 'invalid format')
except AppError as e:
    print(type(e).__name__)                           # ValidationError
    print(e.field)                                    # email
    print(e.msg)                                      # invalid format

# Re-raising
def process(data):
    try:
        if not data:
            raise ValueError('empty data')
        return data.upper()
    except ValueError:
        raise

try:
    process('')
except ValueError as e:
    print(str(e))                                     # empty data

# Exception in else
def safe_div(a, b):
    try:
        result = a / b
    except ZeroDivisionError:
        return None
    else:
        return round(result, 2)

print(safe_div(10, 3))                                # 3.33
print(safe_div(10, 0))                                # None

print('done')
