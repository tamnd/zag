import logging
import io

# Level constants
print(logging.DEBUG)                                       # 10
print(logging.INFO)                                        # 20
print(logging.WARNING)                                     # 30
print(logging.ERROR)                                       # 40
print(logging.CRITICAL)                                    # 50
print(logging.NOTSET)                                      # 0

# getLevelName
print(logging.getLevelName(10))                            # DEBUG
print(logging.getLevelName(20))                            # INFO
print(logging.getLevelName(30))                            # WARNING
print(logging.getLevelName(40))                            # ERROR
print(logging.getLevelName(50))                            # CRITICAL
print(logging.getLevelName(0))                             # NOTSET

# getLogger
logger = logging.getLogger('myapp')
print(logger.name)                                         # myapp
print(logger.level)                                        # 0
logger.setLevel(logging.DEBUG)
print(logger.level)                                        # 10
print(logger.isEnabledFor(logging.DEBUG))                  # True
print(logger.isEnabledFor(logging.WARNING))                # True
logger.setLevel(logging.WARNING)
print(logger.isEnabledFor(logging.DEBUG))                  # False
print(logger.isEnabledFor(logging.WARNING))                # True

# same instance
print(logging.getLogger('myapp') is logger)                # True

# StreamHandler + Formatter
stream = io.StringIO()
handler = logging.StreamHandler(stream)
handler.setLevel(logging.DEBUG)
fmt = logging.Formatter('%(levelname)s:%(name)s:%(message)s')
handler.setFormatter(fmt)
logger.setLevel(logging.DEBUG)
logger.handlers.clear()
logger.addHandler(handler)
logger.propagate = False
logger.debug('d')
logger.info('i')
logger.warning('w')
logger.error('e')
logger.critical('c')
for line in stream.getvalue().strip().split('\n'):
    print(line)                                            # DEBUG:myapp:d ... CRITICAL:myapp:c

# NullHandler
nh = logging.NullHandler()
print(isinstance(nh, logging.Handler))                     # True

# disable
logging.disable(logging.WARNING)
stream2 = io.StringIO()
h2 = logging.StreamHandler(stream2)
h2.setLevel(logging.DEBUG)
h2.setFormatter(fmt)
lg2 = logging.getLogger('disabled')
lg2.setLevel(logging.DEBUG)
lg2.handlers.clear()
lg2.addHandler(h2)
lg2.propagate = False
lg2.warning('should not appear')
lg2.error('should appear')
logging.disable(logging.NOTSET)
for line in stream2.getvalue().strip().split('\n'):
    print(line)                                            # ERROR:disabled:should appear

print('done')
