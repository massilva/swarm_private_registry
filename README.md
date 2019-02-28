# Deploy Swarm + Registry

Após a instalação do [docker](https://docs.docker.com/install/linux/docker-ce/ubuntu/), [docker-compose](https://docs.docker.com/v17.09/compose/install/#install-compose) e do [docker-machine](https://github.com/docker/machine/releases).

Utilizou-se o post [Using private registry in Docker Swarm](https://codeblog.dotsandbrackets.com/private-registry-swarm/) como referência para subir o Swarm + Registry.

**obs**: É necessário instalar o `virtualbox`, para que os comandos do tutorial funcione corretamente.

O script `swarm.sh` pode ser utilizado para auxiliar com uso do Swarm + Registry.

### Passo a passo para subir o Swarm + Registry

1. Na pasta onde tem o script `swarm.sh` crie as pastas `certs` e `auth`:

   * **certs** - conterá os arquivos certificados: `cert.pem`, `domain.crt` e `domain.key`. Se os arquivos não existirem na pasta serão criados ao fazer o `setup`. 
   * **auth** - conterá o arquivo `htpasswd` com os usuários de acesso.

2. Execute o setup
```bash
./swarm.sh init [STACKNAME="privateregistry"] [HOSTNAME="myregistry.com"] [DOCKERMACHINEDRIVER="virtualbox"] [MANAGERNAME="master"] [WORKERS=2] [WORKERNAME="worker-"] [REGISTRYPORT="5001"]
```

O comando acima irá subir o swarm com um node manager  `master` e dois nodes worker com os nomes `worker-1` e `worker-2` (o WORKERNAME é o prefixo do nome do worker e o índice $i da interação é o sufixo).

O hostname `myregistry.com` será adicionado ao `/etc/hosts/`, caso o usuário deseje.

O `STACKNAME` é o nome do serviço dentro do arquivo `docker-compose.yml`

O `REGISTRYPORT` é a porta que o serviço do registry que será exposta.

3. Com o arquivo `docker-compose.yml` na pasta onde tem o script `swarm.sh`, inicie o registry 
```bash
./swarm.sh deploy
```

### Subindo imagem para o registro

**obs**: Se estiver utilizando um certificado auto-assinado é necessário configurar a máquina local para permitir o uso do registry.

#### Certificado auto-assinado

Crie a pasta `$HOSTNAME:$REGISTRYPORT` em `/etc/docker/certs.d/`, no exemplo acima seria criado a pasta com o nome `myregistry.com:5001`.

Neste documento quando for citado `$DOMAIN` será o mesmo que dizer `$HOSTNAME:$REGISTRYPORT`

Copie os certificados do swarm para a máquina.

Copie os certificados para esta pasta:

- `cert/domain.crt` para `ca.crt`
- `cert/domain.key` para `client.key`
- `cert/cert.pem` para `client.cert`

#### Subindo a imagem

Crie a tag de uma imagem a partir de uma imagem existente localmente:

```bash
#./swarm.sh tag SOURCE_IMAGE[:TAG] $DOMAIN/<IMAGENAME>[:TAG]
./swarm.sh tag giiro-apache myregistry.com:5001/giiro_apache:v1
```

**obs**: use `docker images` para vê a lista de imagens disponíveis, caso a imagem que deseja não tenha sido criada pode utilizar `./swarm.sh build <DOCKERFILE> <IMAGENAME>:<VERSION>`

Faça o login no registry:

```bash
#docker login $DOMAIN
docker login myregistry.com:5001

#docker push <IMAGENAME>
docker push myregistry.com:5001/giiro_apache:v1
```

#### Baixando a imagem

Faça o login no registry:

```bash
#docker login $DOMAIN
docker login myregistry.com:5001

#docker pull <IMAGENAME>
docker pull myregistry.com:5001/giiro_apache:v1
```

