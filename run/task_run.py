import os
import multiprocessing
from subprocess import run

def process_config_file(config_file):
    """处理单个配置文件的函数"""
    output_file = None
    with open(config_file, 'r') as f:
        for i, line in enumerate(f):
            if line.startswith('#Filename with approximation results'):
                output_file = line[i+1]
                break
    
    if not output_file:
        print(f"Warning: Could not find output file in {config_file}")
        return
    
    # 检查输出文件是否已存在
    if os.path.exists(output_file):
        print(f"Skipping {config_file} - output {output_file} already exists")
        return
        
    env = os.environ.copy()
    env['OMP_NUM_THREADS'] = '1'
    cmd = ['./sqct', '-G', config_file]
    print(f"Processing: {config_file}")
    run(cmd, env=env, check=True)
    print(f"Completed: {config_file}")

def batch_run_configs(config_dir='configs', max_workers=10):
    """批量运行配置文件"""
    # 获取所有配置文件
    config_files = [
        os.path.join(config_dir, f) 
        for f in os.listdir(config_dir) 
        if f.endswith('.config')
    ]
    config_files.sort()  # 按文件名排序
    
    print(f"Found {len(config_files)} config files to process")
    
    # 创建进程池
    with multiprocessing.Pool(processes=max_workers) as pool:
        pool.map(process_config_file, config_files)
    
    print("All config files processed")

if __name__ == '__main__':
    # 设置参数
    config_directory = 'configs'  # 配置文件所在目录
    num_processes = 10           # 并发进程数
    
    # 运行批处理
    batch_run_configs(config_directory, num_processes)
