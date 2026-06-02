```mermaid
architecture-beta
    group aws(cloud)[AWS Cloud]
    
    service s3_raw(disk)[S3 Bucket: raw] in aws
    service s3_out(disk)[S3 Bucket: output] in aws
    service s3_wiki(disk)[S3 Bucket: wiki] in aws

    group vpc(cloud)[VPC 10.0.0.0/16] in aws
    service igw(internet)[Internet Gateway] in vpc
    
    group endpoints(server)[VPC Endpoints] in vpc
    service s3_gw(network)[S3 Gateway Endpoint] in endpoints
    service ecr_ep(network)[ECR & Logs Endpoints] in endpoints

    group az1(cloud)[Availability Zone 1] in vpc
    group az2(cloud)[Availability Zone 2] in vpc

    %% AZ 1 Subnets
    service nat1(server)[NAT Gateway 1] in az1
    service front1(server)[Frontend Subnet 1] in az1
    service app1(server)[App Subnet 1] in az1
    service llm1(server)[Ollama Fargate 1] in az1
    service db1(database)[RDS Postgres Primary] in az1

    %% AZ 2 Subnets
    service nat2(server)[NAT Gateway 2] in az2
    service front2(server)[Frontend Subnet 2] in az2
    service app2(server)[App Subnet 2] in az2
    service llm2(server)[Ollama Fargate 2] in az2
    service db2(database)[RDS Postgres Standby] in az2

    %% External
    service user(internet)[Internet Users]

    %% Connections
    user:R --> L:igw
    igw:R --> L:front1
    igw:R --> L:front2
    
    front1:B --> T:app1
    front2:B --> T:app2
    
    app1:B --> T:llm1
    app2:B --> T:llm2
    
    app1:B --> T:db1
    app2:B --> T:db2
    
    db1:R --> L:db2

    app1:R --> L:s3_gw
    app2:R --> L:s3_gw
    
    s3_gw:R --> L:s3_raw
    s3_gw:R --> L:s3_out
    
    llm1:L --> R:nat1
    llm2:L --> R:nat2
```