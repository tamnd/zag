import configparser
import io

# Basic ConfigParser
cp = configparser.ConfigParser()
cp.read_string('[server]\nhost=localhost\nport=8080\n[database]\nname=mydb\nuser=admin')
print(sorted(cp.sections()))                               # ['database', 'server']
print(cp.get('server', 'host'))                            # localhost
print(cp.getint('server', 'port'))                        # 8080
print(cp.has_section('database'))                          # True
print(cp.has_option('database', 'name'))                   # True
print(cp.has_option('database', 'missing'))                # False
print(sorted(cp.options('server')))                        # ['host', 'port']
print(dict(cp.items('database')))                          # {'name': 'mydb', 'user': 'admin'}

# fallback
print(cp.get('server', 'host', fallback='default'))        # localhost
print(cp.get('server', 'missing', fallback='fb'))          # fb

# RawConfigParser (no interpolation)
rcp = configparser.RawConfigParser()
rcp.read_string('[s1]\nfoo=%(bar)s\n')
print(rcp.get('s1', 'foo'))                                # %(bar)s

# write / read-back
buf = io.StringIO()
cp.write(buf)
buf.seek(0)
cp2 = configparser.ConfigParser()
cp2.read_string(buf.read())
print(sorted(cp2.sections()))                              # ['database', 'server']

# set / remove
cp3 = configparser.ConfigParser()
cp3.add_section('a')
cp3.set('a', 'k', 'v')
print(cp3.get('a', 'k'))                                   # v
cp3.remove_option('a', 'k')
print(cp3.has_option('a', 'k'))                            # False
cp3.remove_section('a')
print(cp3.has_section('a'))                                # False

# getboolean / getfloat
cp4 = configparser.ConfigParser()
cp4.read_string('[x]\nflag=true\nratio=3.14')
print(cp4.getboolean('x', 'flag'))                         # True
print(cp4.getfloat('x', 'ratio'))                          # 3.14

# DEFAULT section via defaults=
cp5 = configparser.ConfigParser(defaults={'color': 'red'})
cp5.add_section('theme')
print(cp5.get('theme', 'color'))                           # red

# NoSectionError
try:
    cp.get('nosec', 'k')
except configparser.NoSectionError:
    print('NoSectionError')                                # NoSectionError

# NoOptionError
try:
    cp.get('server', 'nosuchkey')
except configparser.NoOptionError:
    print('NoOptionError')                                 # NoOptionError

# DuplicateSectionError
cp6 = configparser.ConfigParser()
cp6.add_section('s')
try:
    cp6.add_section('s')
except configparser.DuplicateSectionError:
    print('DuplicateSectionError')                         # DuplicateSectionError

print('done')
