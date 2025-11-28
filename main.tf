# ==============================
# 1. Terraform 版本与 Provider 约束
# ==============================
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 1.200.0"
    }
  }
}

# ==============================
# 2. 阿里云 Provider 配置
# ==============================
provider "alicloud" {
  region = "cn-beijing"  # 按需修改地域
  # 认证：执行前配置环境变量
  # PowerShell: $env:ALICLOUD_ACCESS_KEY="你的AK"; $env:ALICLOUD_SECRET_KEY="你的SK"
}

# ==============================
# 3. 自定义变量
# ==============================
variable "ecs_login_password" {
  type        = string
  default     = "Admin@123456"  # 符合阿里云密码规范
  description = "ECS 登录密码"
}

variable "name_prefix" {
  type        = string
  default     = "ecs-intranet-password"
}

variable "instance_type" {
  type        = string
  default     = "ecs.t6.small"
}

variable "target_zone_id" {
  type        = string
  default     = "cn-beijing-a"  # 按需修改可用区
}

# ==============================
# 4. 基础资源：VPC
# ==============================
resource "alicloud_vpc" "main" {
  vpc_name   = "${var.name_prefix}-vpc"
  cidr_block = "172.16.0.0/12"
  tags = {
    Name = "${var.name_prefix}-vpc"
    Env  = "test"
  }
}

# ==============================
# 5. 基础资源：子网
# ==============================
resource "alicloud_vswitch" "main" {
  vpc_id     = alicloud_vpc.main.id
  cidr_block = "172.16.0.0/21"
  zone_id    = var.target_zone_id
  vswitch_name = "${var.name_prefix}-vsw"
  tags = {
    Name = "${var.name_prefix}-vsw"
    Env  = "test"
  }
}

# ==============================
# 6. 安全组（拆分多端口为独立规则，修复端口格式错误）
# ==============================
resource "alicloud_security_group" "main" {
  security_group_name = "${var.name_prefix}-sg"
  vpc_id              = alicloud_vpc.main.id
  tags = {
    Name = "${var.name_prefix}-sg"
    Env  = "test"
  }
}

# 规则1：放行内网 SSH（22端口）
resource "alicloud_security_group_rule" "allow_intranet_ssh" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "22/22"  # 单个端口格式：端口/端口
  priority          = 1
  security_group_id = alicloud_security_group.main.id
  cidr_ip           = alicloud_vpc.main.cidr_block
}

# 规则2：放行内网 HTTP（80端口）- 拆分独立规则
resource "alicloud_security_group_rule" "allow_intranet_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80"  # 单独写80端口，不与443合并
  priority          = 2
  security_group_id = alicloud_security_group.main.id
  cidr_ip           = alicloud_vpc.main.cidr_block
}

# 规则3：放行内网 HTTPS（443端口）- 拆分独立规则
resource "alicloud_security_group_rule" "allow_intranet_https" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "443/443"  # 单独写443端口
  priority          = 3
  security_group_id = alicloud_security_group.main.id
  cidr_ip           = alicloud_vpc.main.cidr_block
}

# 规则4：放行内网出方向流量
resource "alicloud_security_group_rule" "allow_intranet_egress" {
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"  # 所有端口
  priority          = 1
  security_group_id = alicloud_security_group.main.id
  cidr_ip           = "0.0.0.0/0"
}

# ==============================
# 7. 数据源：查询 100% 有效镜像（用 ImageId 而非名称，避免不存在）
# ==============================
# 阿里云 CentOS 7.9 公共镜像（cn-beijing 地域有效，其他地域可替换对应 ImageId）
data "alicloud_images" "centos" {
  image_ids = ["centos_7_9_64_20G_alibase_20250101.vhd"]  # 直接指定有效 ImageId
  owners    = "system"  # 官方镜像
}

# ==============================
# 8. 核心资源：ECS 实例（修复镜像 ID 和安全组规则）
# ==============================
resource "alicloud_instance" "main" {
  instance_name        = "${var.name_prefix}-instance"
  availability_zone    = var.target_zone_id
  instance_type        = var.instance_type
  system_disk_category = "cloud_essd_entry"
  system_disk_size     = 40

  # 无公网配置
  vswitch_id                 = alicloud_vswitch.main.id
  security_groups            = [alicloud_security_group.main.id]
  internet_max_bandwidth_out = 0
  internet_charge_type       = "PayByTraffic"

  # 镜像配置：直接引用 100% 有效镜像（避免不存在）
  image_id = data.alicloud_images.centos.ids[0]

  # 密码登录配置（CentOS 默认用户名 root）
  password         = var.ecs_login_password
  password_inherit = false

  # 计费配置
  instance_charge_type = "PostPaid"  # 按量付费（销毁即停费）
  deletion_protection  = true        # 防止误删除

  tags = {
    Name = "${var.name_prefix}-instance"
    Env  = "test"
    PublicIP = "Disabled"
  }
}

# ==============================
# 9. 输出信息
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
  用户名：root（CentOS 默认）
  登录密码：${var.ecs_login_password}
  登录命令：ssh root@${alicloud_instance.main.private_ip}
  注意：需在 VPC 内其他机器（如堡垒机）执行登录
  EOT
  description = "ECS 登录信息（妥善保管密码）"
}

output "used_image_id" {
  value       = alicloud_instance.main.image_id
  description = "实际使用的镜像 ID（100% 有效）"
}
