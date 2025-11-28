# ==============================
# 1. Terraform 版本与 Provider 约束（避免兼容性问题）
# ==============================
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 1.200.0"  # 推荐版本，稳定兼容
    }
  }
}

# ==============================
# 2. 阿里云 Provider 配置（认证+地域）
# ==============================
provider "alicloud" {
  region = "cn-beijing"  # 按需修改部署地域
  # 认证方式：环境变量配置 AK/SK（执行前设置）
  # PowerShell: $env:ALICLOUD_ACCESS_KEY="你的AK"; $env:ALICLOUD_SECRET_KEY="你的SK"
  # Linux: export ALICLOUD_ACCESS_KEY="你的AK"; export ALICLOUD_SECRET_KEY="你的SK"
}

# ==============================
# 3. 自定义变量（含 ECS 登录密码，可修改）
# ==============================
variable "ecs_login_password" {
  type        = string
  default     = "Admin@123456"  # 自定义密码（需符合阿里云密码规范）
  description = "ECS 实例登录密码（要求：8-30位，含大小写字母+数字+特殊字符）"
}

variable "name_prefix" {
  type        = string
  default     = "ecs-intranet-password"
  description = "资源名称前缀"
}

variable "instance_type" {
  type        = string
  default     = "ecs.t6.small"  # 2核2G，内网场景足够
  description = "ECS 实例规格"
}

variable "target_zone_id" {
  type        = string
  default     = "cn-beijing-a"  # 按需修改可用区
  description = "子网和 ECS 所在可用区"
}

# ==============================
# 4. 基础资源：VPC（内网核心网络）
# ==============================
resource "alicloud_vpc" "main" {
  vpc_name   = "${var.name_prefix}-vpc"
  cidr_block = "172.16.0.0/12"  # VPC 内网网段
  description = "无公网、密码登录 ECS 专用 VPC"
  tags = {
    Name = "${var.name_prefix}-vpc"
    Env  = "test"
    Auth = "Password"
  }
}

# ==============================
# 5. 基础资源：子网（与 ECS 同可用区）
# ==============================
resource "alicloud_vswitch" "main" {
  vpc_id     = alicloud_vpc.main.id
  cidr_block = "172.16.0.0/21"  # 子网网段（VPC 子集）
  zone_id    = var.target_zone_id
  vswitch_name = "${var.name_prefix}-vsw"
  tags = {
    Name = "${var.name_prefix}-vsw"
    Env  = "test"
  }
}

# ==============================
# 6. 安全组（仅开放内网访问，支持密码登录）
# ==============================
resource "alicloud_security_group" "main" {
  security_group_name = "${var.name_prefix}-sg"
  vpc_id              = alicloud_vpc.main.id
  description         = "无公网 ECS 安全组（密码登录，仅内网访问）"
  tags = {
    Name = "${var.name_prefix}-sg"
    Env  = "test"
  }
}

# 安全组规则：仅允许 VPC 内网 SSH 登录（22端口，密码登录用）
resource "alicloud_security_group_rule" "allow_intranet_ssh" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"  # 仅内网流量
  policy            = "accept"
  port_range        = "22/22"     # SSH 端口（密码登录需开放）
  priority          = 1
  security_group_id = alicloud_security_group.main.id
  cidr_ip           = alicloud_vpc.main.cidr_block  # 仅 VPC 内网访问
}

# 安全组规则：允许内网 HTTP/HTTPS（可选，内网 Web 服务用）
resource "alicloud_security_group_rule" "allow_intranet_web" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80,443/443"
  priority          = 2
  security_group_id = alicloud_security_group.main.id
  cidr_ip           = alicloud_vpc.main.cidr_block
}

# 安全组规则：允许所有内网出方向流量
resource "alicloud_security_group_rule" "allow_intranet_egress" {
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.main.id
  cidr_ip           = "0.0.0.0/0"
}

# ==============================
# 7. 数据源：动态查询 Ubuntu 20.04 官方镜像（修复兼容性）
# ==============================
data "alicloud_images" "centos" {
  name_regex  = "^centos_7_9_64"  # CentOS 7.9 64位
  most_recent = true
  owners      = "system"
  architecture = "x86_64"
}



# ==============================
# 8. 核心资源：无公网 ECS 实例（密码登录）
# ==============================
resource "alicloud_instance" "main" {
  # 基础配置
  instance_name        = "${var.name_prefix}-instance"
  availability_zone    = var.target_zone_id
  instance_type        = var.instance_type
  system_disk_category = "cloud_essd_entry"  # 高效系统盘
  system_disk_size     = 40                  # 系统盘 40GB

  # 网络配置（无公网）
  vswitch_id                 = alicloud_vswitch.main.id
  security_groups            = [alicloud_security_group.main.id]
  internet_max_bandwidth_out = 0  # 关闭公网 IP
  internet_charge_type       = "PayByTraffic"  # 无公网不产生费用

  # 镜像 + 密码登录配置（核心修改：取消密钥对，用密码）
 image_id = length(data.alicloud_images.centos.ids) > 0 ? data.alicloud_images.centos.ids[0] : "centos_7_9_64_20G_alibase_20230612.vhd"
  password           = var.ecs_login_password  # 自定义登录密码
  password_inherit   = false                   # 禁用密码继承（使用自定义密码）


  # 计费配置（按量付费，测试环境推荐）
  instance_charge_type = "PostPaid"  # 按量付费（销毁即停费）
  # 若需包年包月，替换为：
  # instance_charge_type = "PrePaid"
  # period               = 1  # 购买1个月
  # auto_renew           = false

  # 其他配置
  deletion_protection = true  # 防止误删除
  tags = {
    Name = "${var.name_prefix}-instance"
    Env  = "test"
    PublicIP = "Disabled"
    Auth     = "Password"
  }
}

# ==============================
# 9. 输出关键信息（含登录密码提示）
# ==============================
output "ecs_id" {
  value       = alicloud_instance.main.id
  description = "ECS 实例 ID"
}

output "ecs_private_ip" {
  value       = alicloud_instance.main.private_ip
  description = "ECS 内网 IP（仅 VPC 内可访问）"
}

output "login_info" {
  value = <<EOT
  登录方式：SSH 密码登录（仅 VPC 内网）
  登录地址：${alicloud_instance.main.private_ip}
  用户名（Ubuntu）：ubuntu
  用户名（CentOS）：root
  登录密码：${var.ecs_login_password}（已在变量中配置，可修改）
  登录命令：ssh ubuntu@${alicloud_instance.main.private_ip}（输入密码即可）
  注意：需在 VPC 内其他机器（如堡垒机）执行登录命令
  EOT
  description = "ECS 登录信息（请妥善保管密码）"
}

output "network_info" {
  value = <<EOT
  网络模式：仅内网（无公网 IP）
  VPC 网段：${alicloud_vpc.main.cidr_block}
  子网网段：${alicloud_vswitch.main.cidr_block}
  访问限制：仅 VPC 内资源可访问该 ECS
  EOT
  description = "网络访问说明"
}
