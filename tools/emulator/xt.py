import ctypes, sys, time
x=ctypes.cdll.LoadLibrary("libX11.so.6"); t=ctypes.cdll.LoadLibrary("libXtst.so.6")
x.XOpenDisplay.restype=ctypes.c_void_p
d=ctypes.c_void_p(x.XOpenDisplay(b":99"))
x.XDefaultRootWindow.restype=ctypes.c_ulong
root=ctypes.c_ulong(x.XDefaultRootWindow(d))
OX,OY=133,88
def child():
    r=ctypes.c_ulong();c=ctypes.c_ulong();a=ctypes.c_int();b=ctypes.c_int();e=ctypes.c_int();f=ctypes.c_int();m=ctypes.c_uint()
    x.XQueryPointer(d,root,ctypes.byref(r),ctypes.byref(c),ctypes.byref(a),ctypes.byref(b),ctypes.byref(e),ctypes.byref(f),ctypes.byref(m))
    return c.value
def tap(px,py,hold=0.0):
    t.XTestFakeMotionEvent(d,-1,OX+px,OY+py,0); x.XSync(d,0); time.sleep(0.15)
    c=child()
    if c: x.XSetInputFocus(d,ctypes.c_ulong(c),1,0); x.XSync(d,0)
    t.XTestFakeButtonEvent(d,1,1,0); x.XSync(d,0); time.sleep(0.1+hold)
    t.XTestFakeButtonEvent(d,1,0,0); x.XSync(d,0)
def key(s):
    x.XKeysymToKeycode.restype=ctypes.c_ubyte
    x.XStringToKeysym.restype=ctypes.c_ulong
    for ch in s:
        name={' ':b'space'}.get(ch, ch.encode())
        ks=x.XStringToKeysym(name); kc=x.XKeysymToKeycode(d,ctypes.c_ulong(ks))
        shift = ch.isupper()
        if shift: t.XTestFakeKeyEvent(d,x.XKeysymToKeycode(d,ctypes.c_ulong(0xffe1)),1,0)
        t.XTestFakeKeyEvent(d,kc,1,0); t.XTestFakeKeyEvent(d,kc,0,0)
        if shift: t.XTestFakeKeyEvent(d,x.XKeysymToKeycode(d,ctypes.c_ulong(0xffe1)),0,0)
        x.XSync(d,0); time.sleep(0.06)
a=sys.argv[1:]
if a[0]=="tap": tap(int(a[1]),int(a[2]), float(a[3]) if len(a)>3 else 0)
elif a[0]=="key": key(" ".join(a[1:]))
