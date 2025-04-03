import os

def generate_config_files(m_min, m_max, k_per_batch=1024, k_step=2):
    """
    生成批量配置文件
    
    参数:
    m_min: n的最小指数 (n=2^m)
    m_max: n的最大指数
    k_per_batch: 每个配置文件的k值数量
    k_step: k的步长
    """
    os.makedirs("configs", exist_ok=True)
    
    for m in range(m_min, m_max + 1):
        n = 2 ** m
        max_k = n // 2         
        
        total_k_values = (max_k - 1) // k_step + 1
        num_batches = (total_k_values + k_per_batch - 1) // k_per_batch
        
        for batch in range(num_batches):
            k1 = 1 + batch * k_per_batch * k_step
            k2 = min(k1 + k_per_batch * k_step, max_k + 1)
            
            config_content = f"""# Request approximation of R_z rotations by angles of the form $2\\pi k/n$ for k in the interval [k1,k2)
UNIFORM
#Filename with approximation results
batch_out/uni{n}_{batch+1}.txt
#Minimal number of T gates to use for approximation
0
#Maximal number of T gates to use for approximation
100
#n
{n}
#k1
{k1}
#k2
{k2}
#kstep
{k_step}
"""
            filename = f"configs/uni{n}_{batch+1}.config"
            with open(filename, 'w') as f:
                f.write(config_content)
            
            print(f"Generated config file: {filename}")

generate_config_files(m_min=21, m_max=21)
