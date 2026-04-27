# logging module basics

import logging
import io

# Basic logging levels
print(logging.DEBUG)                               # 10
print(logging.INFO)                                # 20
print(logging.WARNING)                             # 30
print(logging.ERROR)                               # 40
print(logging.CRITICAL)                            # 50

# Logger creation
logger = logging.getLogger('test')
logger.setLevel(logging.DEBUG)

# StreamHandler with StringIO
stream = io.StringIO()
handler = logging.StreamHandler(stream)
handler.setLevel(logging.DEBUG)
formatter = logging.Formatter('%(levelname)s: %(message)s')
handler.setFormatter(formatter)
logger.addHandler(handler)

# Log messages
logger.debug('debug message')
logger.info('info message')
logger.warning('warning message')
logger.error('error message')
logger.critical('critical message')

output = stream.getvalue()
lines = output.strip().split('\n')
for line in lines:
    print(line)

# effectiveLevel
logger2 = logging.getLogger('myapp2')
logger2.setLevel(logging.WARNING)
print(logger2.getEffectiveLevel())                 # 30

# isEnabledFor
print(logger.isEnabledFor(logging.DEBUG))          # True
print(logger.isEnabledFor(logging.NOTSET))         # True

# getLevelName
print(logging.getLevelName(10))                    # DEBUG
print(logging.getLevelName(30))                    # WARNING
print(logging.getLevelName('DEBUG'))               # 10

# Null handler
null = logging.NullHandler()
print(null.level)                                  # 0

print('done')
