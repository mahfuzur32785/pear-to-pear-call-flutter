import socketio
from aiohttp import web

sio = socketio.AsyncServer(cors_allowed_origins="*")
app = web.Application()
sio.attach(app)

@sio.event
async def connect(sid, environ):
    print(f"Client connected: {sid}")

@sio.event
async def join(sid, data):
    room = data['room']
    await sio.enter_room(sid, room)
    print(f"{sid} joined room {room}")
    await sio.emit('user-joined', {'id': sid}, room=room, skip_sid=sid)

@sio.event
async def signal(sid, data):
    # forward signaling data to the target user
    await sio.emit('signal', data, to=data['to'])

@sio.event
async def disconnect(sid):
    print(f"Client disconnected: {sid}")

if __name__ == '__main__':
    web.run_app(app, port=5000)
