# ==============================
# 1. 阿里云 Provider 配置（认证+地域）
# ==============================
provider "alicloud" {
  region = "cn-beijing"  # 部署地域（按需修改）
  # 认证方式：环境变量配置 AK/SK（执行前设置）
  # PowerShell: $env:ALICLOUD_ACCESS_KEY="你的AK"; $env:ALICLOUD_SECRET_KEY="你的SK"
  # Linux: export ALICLOUD_ACCESS_KEY="你的AK"; export ALICLOUD_SECRET_KEY="你的SK"
}

# ==============================
# 2. 基础资源：VPC（内网核心网络）
# ==============================
resource "alicloud_vpc" "ecs_vpc" {
  vpc_name   = "ecs-intranet-vpc"
  cidr_block = "172.16.0.0/12"  # VPC 内网网段
  description = "无公网 ECS 专用 VPC"
  tags = { Name = "ecs-intranet-vpc", Env = "test", Network = "Intranet-Only" }
}

# ==============================
# 3. 基础资源：子网（与 ECS 同可用区）
# ==============================
resource "alicloud_vswitch" "ecs_vsw" {
  vpc_id     = alicloud_vpc.ecs_vpc.id
  cidr_block = "172.16.0.0/21"  # 子网网段（VPC 子集）
  zone_id    = "cn-beijing-a"  # 按需修改为目标可用区（需与 ECS 一致）
  vswitch_name = "ecs-intranet-vsw"
  tags = { Name = "ecs-intranet-vsw", Env = "test" }
}

# ==============================
# 4. 安全组（仅开放内网访问规则）
# ==============================
resource "alicloud_security_group" "ecs_sg" {
  security_group_name = "ecs-intranet-sg"
  vpc_id              = alicloud_vpc.ecs_vpc.id
  description         = "无公网 ECS 安全组（仅内网访问）"
  tags = { Name = "ecs-intranet-sg", Env = "test" }
}

# 安全组规则：仅允许内网 SSH 登录（避免公网暴露 22 端口）
# 说明：cidr_ip 限制为 VPC 网段，仅 VPC 内其他资源可访问
resource "alicloud_security_group_rule" "allow_intranet_ssh" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"  # 仅内网流量
  policy            = "accept"
  port_range        = "22/22"     # SSH 端口（仅内网可用）
  priority          = 1
  security_group_id = alicloud_security_group.ecs_sg.id
  cidr_ip           = alicloud_vpc.ecs_vpc.cidr_block  # 限制 VPC 内网访问
}

# 安全组规则：允许内网 HTTP/HTTPS 访问（若需内网 Web 服务）
resource "alicloud_security_group_rule" "allow_intranet_web" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80,443/443"
  priority          = 2
  security_group_id = alicloud_security_group.ecs_sg.id
  cidr_ip           = alicloud_vpc.ecs_vpc.cidr_block
}

# 安全组规则：允许所有内网出方向流量（ECS 访问内网其他服务）
resource "alicloud_security_group_rule" "allow_intranet_egress" {
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.ecs_sg.id
  cidr_ip           = "0.0.0.0/0"
}

# ==============================
# 5. 密钥对（ECS 内网登录用）
# ==============================
resource "alicloud_key_pair" "ecs_key" {
  key_pair_name = "ecs-intranet-key"
  provisioner "local-exec" {
    command = <<EOT
      # Windows 保存私钥（用于内网 SSH 登录）
      $privateKey = "${self.private_key}"
      $privateKey | Out-File -FilePath "ecs-intranet-key.pem" -Encoding ASCII
      icacls "ecs-intranet-key.pem" /inheritance:r
      icacls "ecs-intranet-key.pem" /grant:r "$env:USERNAME:(R)"
      # Linux/Mac 请替换为：
      # echo "${self.private_key}" > ecs-intranet-key.pem && chmod 600 ecs-intranet-key.pem
    EOT
  }
}

# ==============================
# 6. 数据源：动态查询 Ubuntu 20.04 镜像（避免镜像 ID 失效）
# ==============================
data "alicloud_images" "ubuntu_2004" {
  name_regex  = "^ubuntu_20_04_64"
  most_recent = true
  owners      = ["system"]  # 阿里云官方镜像
}

# ==============================
# 7. 核心资源：无公网 ECS 实例（关键配置）
# ==============================
resource "alicloud_instance" "ecs" {
  # 基础配置
  instance_name        = "ecs-intranet-instance"
  availability_zone    = alicloud_vswitch.ecs_vsw.zone_id  # 与子网同可用区
  instance_type        = "ecs.t6.small"  # 2核2G，内网场景足够
  system_disk_category = "cloud_essd_entry"  # 高效系统盘
  system_disk_size     = 40  # 系统盘大小（GB）

  # 网络配置：关闭公网（核心修改）
  vswitch_id                 = alicloud_vswitch.ecs_vsw.id  # 绑定内网子网
  security_groups            = [alicloud_security_group.ecs_sg.id]  # 内网安全组
  internet_max_bandwidth_out = 0  # 公网出带宽设为 0 → 不分配公网 IP
  internet_charge_type       = "PayByTraffic"  # 带宽计费（无公网时不产生费用）

  # 镜像 + 登录配置
  image_id = data.alicloud_images.ubuntu_2004.ids[0]  # 动态镜像 ID
  key_name = alicloud_key_pair.ecs_key.key_pair_name  # 密钥对登录（更安全）

  # 计费配置（按量付费，内网场景成本更低）
  instance_charge_type = "PostPaid"  # 按量付费（销毁即停止收费）
  # 若需包年包月，替换为：
  # instance_charge_type = "PrePaid"
  # period               = 1  # 购买1个月
  # auto_renew           = false

  # 其他配置
  deletion_protection = true  # 防止误删除
  tags = { 
    Name = "ecs-intranet-instance", 
    Env = "test", 
    PublicIP = "Disabled" 
  }
}

# ==============================
# 8. 输出关键信息（仅内网相关）
# ==============================
output "ecs_id" {
  value = alicloud_instance.ecs.id
  description = "ECS 实例 ID"
}

output "ecs_private_ip" {
  value = alicloud_instance.ecs.private_ip
  description = "ECS 内网 IP（仅 VPC 内可访问）"
}

output "intranet_ssh_command" {
  value = "ssh -i ecs-intranet-key.pem ubuntu@${alicloud_instance.ecs.private_ip}"
  description = "内网 SSH 登录命令（需在 VPC 内其他机器执行）"
}

output "network_info" {
  value = <<EOT
  网络模式：仅内网（无公网 IP）
  VPC 网段：${alicloud_vpc.ecs_vpc.cidr_block}
  子网网段：${alicloud_vswitch.ecs_vsw.cidr_block}
  访问限制：仅 VPC 内资源可访问该 ECS
  EOT
  description = "网络访问说明"
}
