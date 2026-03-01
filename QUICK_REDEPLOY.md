# WorkflowAI Quick Redeploy Guide

快速一键重新部署整个WorkflowAI系统到AWS EC2。

## 功能特性

✅ **完全自动化** - 一个命令完成所有部署步骤  
✅ **使用已有IAM Role** - 不重复创建权限配置  
✅ **SSM连接** - 无需SSH密钥，通过Systems Manager连接  
✅ **完整验证** - 自动检查服务状态  
✅ **详细日志** - 彩色输出，清晰的进度提示  
✅ **错误恢复** - 失败时自动清理资源  

---

## 前置要求

- WSL环境 (Windows Subsystem for Linux)
- AWS CLI已配置
- 企业网络环境需要: `export AWS_CLI_SSL_NO_VERIFY=1`
- 已存在IAM Role: `WorkflowAI-SSM-FixedRole`

---

## 快速开始

### 1. 默认部署 (t3.xlarge)

```bash
wsl -e bash quick-redeploy-ec2.sh
```

**实例配置**:
- 类型: t3.xlarge (4 vCPU, 16GB RAM)
- 存储: 30GB gp3
- 地区: ap-southeast-1

---

### 2. 自定义实例类型

```bash
# 更大的实例 (更快的性能)
wsl -e bash quick-redeploy-ec2.sh t3.2xlarge

# 更小的实例 (节省成本，但可能较慢)
wsl -e bash quick-redeploy-ec2.sh t3.large
```

**推荐实例类型**:
| 实例类型 | vCPU | 内存 | 适用场景 |
|---------|------|------|---------|
| t3.large | 2 | 8GB | 测试/开发 (较慢) |
| t3.xlarge | 4 | 16GB | **Day 10标准配置** ⭐ |
| t3.2xlarge | 8 | 32GB | 生产环境/高负载 |

---

## 部署流程

脚本会自动执行以下步骤：

```
1. ✅ 验证IAM Role存在
2. ✅ 创建/检查Instance Profile
3. ✅ 创建/检查Security Group
4. ✅ 启动EC2实例
5. ✅ 等待SSM Agent就绪
6. ✅ 执行User Data脚本:
   - 安装Docker + Docker Compose
   - 克隆workflow-ai仓库
   - 启动所有服务 (11个容器)
7. ✅ 验证服务状态
8. ✅ 输出连接信息
```

**预计时间**: 5-10分钟 (首次部署需要下载Docker镜像)

---

## 部署完成后

### 连接到实例

```bash
# 脚本会输出类似命令:
wsl -e bash -c "export AWS_CLI_SSL_NO_VERIFY=1 && aws ssm start-session --region ap-southeast-1 --target i-xxxxxxxxxxxxx"
```

### 测试Agent工作流

```bash
# 在EC2实例上执行:
cd /home/ec2-user/workflow-ai

# 测试日志分析
curl -X POST http://localhost:8002/workflows/analyze-log \
  -H "Content-Type: application/json" \
  -d @test-payload.json | python3 -m json.tool
```

**预期结果** (4-5分钟):
```json
{
    "analysis_id": "...",
    "root_cause": "Network latency or firewall restrictions...",
    "severity": "high",
    "suggested_fixes": ["..."],
    "references": ["..."],
    "confidence": 0.95
}
```

### 查看日志

```bash
# 查看Agent服务日志
docker-compose logs -f agent-orchestrator

# 查看Model服务日志
docker-compose logs -f model-service

# 查看所有服务状态
docker-compose ps
```

---

## 清理资源

### 终止实例 (保留IAM Role)

```bash
# 脚本会输出清理命令:
wsl -e bash -c "export AWS_CLI_SSL_NO_VERIFY=1 && aws ec2 terminate-instances --region ap-southeast-1 --instance-ids i-xxxxxxxxxxxxx"
```

**保留的资源**:
- ✅ IAM Role: `WorkflowAI-SSM-FixedRole` (可重复使用)
- ✅ Security Group: `workflow-ai-sg` (可重复使用)
- ✅ Instance Profile: `WorkflowAI-SSM-FixedRole` (可重复使用)

### 完全清理 (包括IAM Role)

如果需要删除所有资源:

```bash
wsl -e bash -c "export AWS_CLI_SSL_NO_VERIFY=1 && \
  # 终止实例
  aws ec2 terminate-instances --region ap-southeast-1 --instance-ids i-xxxxxxxxxxxxx && \
  # 等待实例终止
  aws ec2 wait instance-terminated --region ap-southeast-1 --instance-ids i-xxxxxxxxxxxxx && \
  # 删除Security Group
  aws ec2 delete-security-group --region ap-southeast-1 --group-name workflow-ai-sg && \
  # 删除Instance Profile
  aws iam remove-role-from-instance-profile --instance-profile-name WorkflowAI-SSM-FixedRole --role-name WorkflowAI-SSM-FixedRole && \
  aws iam delete-instance-profile --instance-profile-name WorkflowAI-SSM-FixedRole && \
  # 删除IAM Role
  aws iam detach-role-policy --role-name WorkflowAI-SSM-FixedRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore && \
  aws iam detach-role-policy --role-name WorkflowAI-SSM-FixedRole --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess && \
  aws iam delete-role --role-name WorkflowAI-SSM-FixedRole"
```

---

## 故障排查

### 问题1: SSM Agent未能上线

**症状**: 脚本卡在 "Waiting for SSM agent to be ready"

**解决方案**:
```bash
# 检查实例状态
wsl -e bash -c "export AWS_CLI_SSL_NO_VERIFY=1 && aws ec2 describe-instances --region ap-southeast-1 --instance-ids i-xxxxxxxxxxxxx"

# 检查IAM Role是否正确附加
wsl -e bash -c "export AWS_CLI_SSL_NO_VERIFY=1 && aws ec2 describe-iam-instance-profile-associations --region ap-southeast-1"
```

### 问题2: Docker服务未启动

**症状**: `docker-compose ps` 显示服务未运行

**解决方案**:
```bash
# 连接到实例
wsl -e bash -c "export AWS_CLI_SSL_NO_VERIFY=1 && aws ssm start-session --region ap-southeast-1 --target i-xxxxxxxxxxxxx"

# 查看User Data执行日志
sudo tail -100 /var/log/cloud-init-output.log

# 手动启动服务
cd /home/ec2-user/workflow-ai
docker-compose up -d

# 查看失败原因
docker-compose logs
```

### 问题3: Model Service下载缓慢

**症状**: 首次请求等待很久

**原因**: Qwen2.5-1.5B-Instruct模型首次下载 (~3GB)

**解决方案**:
```bash
# 检查下载进度
docker-compose logs -f model-service

# 等待直到看到: "Model loaded successfully"
```

### 问题4: Instance Profile不存在错误

**症状**: 
```
An error occurred (NoSuchEntity) when calling the GetInstanceProfile operation
```

**解决方案**:
脚本会自动创建Instance Profile，但如果手动删除了Role，需要重新创建：

```bash
wsl -e bash -c "export AWS_CLI_SSL_NO_VERIFY=1 && \
  aws iam create-role --role-name WorkflowAI-SSM-FixedRole --assume-role-policy-document '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}' && \
  aws iam attach-role-policy --role-name WorkflowAI-SSM-FixedRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore && \
  aws iam attach-role-policy --role-name WorkflowAI-SSM-FixedRole --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
```

---

## 脚本输出示例

```
[INFO] Starting WorkflowAI EC2 deployment...
[INFO] Region: ap-southeast-1
[INFO] Instance Type: t3.xlarge
[INFO] Instance Name: workflow-ai-20260301-122530
[INFO] Checking IAM role: WorkflowAI-SSM-FixedRole
[SUCCESS] IAM role found: arn:aws:iam::589528730663:role/WorkflowAI-SSM-FixedRole
[INFO] Checking instance profile...
[SUCCESS] Instance profile already exists
[INFO] Checking security group...
[SUCCESS] Security group exists: sg-0d2a8ce44064e1b42
[INFO] Preparing user data script...
[INFO] Launching EC2 instance...
[SUCCESS] Instance launched: i-04c15212545859456
[INFO] Waiting for instance to be running...
[SUCCESS] Instance is running
[INFO] Private IP: 172.31.19.30
[INFO] Waiting for SSM agent to be ready (may take 2-3 minutes)...
............
[SUCCESS] SSM agent is online!
[INFO] Waiting for deployment to complete (this may take 5-10 minutes)...
[WARN] The instance is downloading Docker images and starting services...
....................
[SUCCESS] Deployment completed!
[INFO] Verifying services...
[SUCCESS] Service status retrieved

========================================================================
[SUCCESS] WorkflowAI Deployment Complete!
========================================================================

[INFO] Instance Details:
  Instance ID:   i-04c15212545859456
  Instance Type: t3.xlarge
  Private IP:    172.31.19.30
  Region:        ap-southeast-1

[INFO] Connect to instance (SSM Session Manager):
  wsl -e bash -c "export AWS_CLI_SSL_NO_VERIFY=1 && aws ssm start-session --region ap-southeast-1 --target i-04c15212545859456"

[INFO] Test Agent Workflow:
  # After connecting via SSM:
  cd /home/ec2-user/workflow-ai
  curl -X POST http://localhost:8002/workflows/analyze-log -H 'Content-Type: application/json' -d @test-payload.json | python3 -m json.tool

[INFO] Cleanup when done:
  wsl -e bash -c "export AWS_CLI_SSL_NO_VERIFY=1 && aws ec2 terminate-instances --region ap-southeast-1 --instance-ids i-04c15212545859456"

[SUCCESS] Instance info saved to: workflow-ai-instance-info.txt
```

---

## 成本估算 (ap-southeast-1)

| 实例类型 | 按需价格/小时 | 每天成本 | 适用场景 |
|---------|------------|---------|---------|
| t3.large | ~$0.096 | ~$2.30 | 开发测试 |
| t3.xlarge | ~$0.192 | ~$4.61 | **标准配置** ⭐ |
| t3.2xlarge | ~$0.384 | ~$9.22 | 生产环境 |

💡 **省钱技巧**: 
- 使用完立即终止实例
- 考虑Spot实例 (节省50-70%)
- 非工作时间停止实例

---

## 高级配置

### 自定义AMI

编辑脚本第27行:
```bash
AMI_ID="ami-047126e50991d067b"  # 改为你的自定义AMI
```

### 自定义存储大小

编辑脚本第224行:
```bash
--block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]'
# 改 VolumeSize 为你需要的大小 (GB)
```

### 使用不同Region

编辑脚本第24行:
```bash
REGION="us-west-2"  # 改为你需要的区域
```

记得同时更新AMI_ID为对应区域的AMI。

---

## 相关文档

- [Day 10 完整报告](../README.md#day-10-rag-agent-workflow-deployment)
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [Docker Compose 文档](https://docs.docker.com/compose/)

---

## 支持

遇到问题？查看:
1. `/var/log/cloud-init-output.log` - User Data执行日志
2. `docker-compose logs` - 服务日志
3. `workflow-ai-instance-info.txt` - 实例信息记录

---

**最后更新**: 2026-03-01  
**脚本版本**: 1.0  
**测试状态**: ✅ 已验证 (Day 10 成功部署)
