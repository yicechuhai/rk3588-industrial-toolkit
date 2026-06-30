import yaml
with open('/opt/rk3588-toolkit/config/engine.yaml') as f:
    c = yaml.safe_load(f)
c['model']['path'] = '/opt/rk3588-toolkit/models/yolov5s.rknn'
c['model']['backup']['path'] = '/opt/rk3588-toolkit/models/yolov5s.rknn'
with open('/opt/rk3588-toolkit/config/engine.yaml', 'w') as f:
    yaml.dump(c, f)
print('Config fixed')
