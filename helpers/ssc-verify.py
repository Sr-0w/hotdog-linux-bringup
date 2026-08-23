#!/usr/bin/env python3
import ctypes, importlib.util, pathlib, socket, struct, sys, time
HERE=pathlib.Path("/root")
S=importlib.util.spec_from_file_location("c", HERE/"ssc-client.py")
SSC=importlib.util.module_from_spec(S); S.loader.exec_module(SSC)
node,port=SSC.find_service()
def run(name, txt, msgid, cfg, secs=6):
    low,high=int(txt[16:],16),int(txt[:16],16)
    fd=SSC.libc.socket(SSC.AF_QIPCRTR, socket.SOCK_DGRAM,0)
    for c in range(12):
        a=SSC.SockaddrQrtr(SSC.AF_QIPCRTR,c,0)
        if SSC.libc.bind(fd,ctypes.byref(a),ctypes.sizeof(a))==0: break
    susp=SSC.pb_uint(1,1)+SSC.pb_uint(2,0)
    body=(SSC.pb_bytes(1,SSC.suid_msg(low,high))+SSC.field(2,5,struct.pack("<I",msgid))
          +SSC.pb_bytes(3,susp)+SSC.pb_bytes(4,SSC.pb_bytes(2,cfg) if cfg else b""))
    pkt=SSC.qmi_request(1,SSC.SNS_CLIENT_REQ,body)
    dst=SSC.SockaddrQrtr(SSC.AF_QIPCRTR,node,port)
    SSC.libc.sendto(fd,ctypes.create_string_buffer(pkt),len(pkt),0,ctypes.byref(dst),ctypes.sizeof(dst))
    SSC.libc.setsockopt(fd,socket.SOL_SOCKET,socket.SO_RCVTIMEO,struct.pack("qq",2,0),16)
    rb=ctypes.create_string_buffer(4096); end=time.time()+secs; n=0; first=None
    while time.time()<end:
        r=SSC.libc.recv(fd,rb,4096,0)
        if r<=0: continue
        d=rb.raw[:r]; i=0
        while True:
            i=d.find(b"\x0d",i+1)
            if i<0 or i+5>len(d): break
            if struct.unpack_from("<I",d,i+1)[0]==1025:
                n+=1
                j=d.find(b"\x0a",i)
                if 0<j<i+40 and j+2<len(d):
                    ln=d[j+1]
                    if 4<=ln<=48 and j+2+ln<=len(d) and ln%4==0:
                        v=struct.unpack("<%df"%(ln//4),d[j+2:j+2+ln])
                        if first is None: first=v
    SSC.libc.close(fd)
    vals=" ".join("%8.3f"%x for x in first[:4]) if first else "-"
    print("  %-20s %4d ech.  %s"%(name,n,vals))
f=SSC.field(1,5,struct.pack("<f",25.0))
run("accel  (m/s2)","1fbb6afc01727ea69a418d19f8d7ba44",513,f)
run("gyro   (rad/s)","97d3c48969f972a0b9418a10491511c1",513,f)
run("mag    (uT)","64bba517c99048b0ac450869b71d795b",513,f)
run("sensor_temperature","973615c0c0808fa3af4002dc9cb83279",513,f)
run("ambient_light","5f5f5f534c4131303733534354736d61",514,None)
run("proximity","5f5f584f525031303733534354736d61",514,None)
run("motion_detect","0b68a5cde246ab85774ada686d1a4bcd",514,None)
run("sars","7335663959f5698867456bc70a6c70ca",514,None)
