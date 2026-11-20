import "reflect-metadata";
import { Controller, Get, Module } from "@nestjs/common";
import { NestFactory } from "@nestjs/core";

@Controller()
class AppController {
  @Get() hello() { return "nest fixture"; }
  @Get("health") health() { return "ok"; }
}

@Module({ controllers: [AppController] })
class AppModule {}

NestFactory.create(AppModule).then((app) => app.listen(process.env.PORT ?? 3000));
